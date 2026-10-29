#!/usr/bin/env bash
# Build geoffcloud's NixOS system from a clean checkout of main, then switch the host to it.
# Run it from the repo:
#
#   bash scripts/switch-geoffcloud.sh               # build, then switch
#   bash scripts/switch-geoffcloud.sh --build-only  # build and print the system path
#   bash scripts/switch-geoffcloud.sh --allow-k3s-restart  # switch in a planned k3s window
#
# A switch first needs a green NixOS checks run that covers the commit; with none, it stops
# before the build and names the command that starts one. It also stops, before the build and
# again before the activation, when the commit's atc daemon pin and a running atc gateway pod's
# image differ in atc major version, since atc breaks its daemon protocol only in a major release,
# and when the running nixie refuses the commit's impd major (check-nixie-impd-major.sh). Before
# the build it also stops when the commit's impd stores a secret kind that its atc daemon pin does
# not accept (check-atc-secret-kinds.sh), so the switch never starts that impd.
# After the copy it holds a switch whose activation would stop or restart k3s, which can keep
# nixie down for minutes, unless --allow-k3s-restart names a planned k3s window
# (check-k3s-restart.sh).
# After the activation it waits for nixie's /health/ready to report every part ready
# (check-nixie-ready.sh), and fails with each part that is not, since nixie needs impd to start.
# Then it fails with each impd image record whose build folder is gone (check-impd-image-dirs.sh),
# since every imp boot from such an image fails. Last it fails when the host reserved fewer
# hugetlb pages than its system configures (check-hugetlb-pool.sh), since impd refuses each boot
# and wake past them, and a reboot reserves the whole pool.
# Once every check passes, it moves origin's deployed/host tag to the switched commit, so a change
# that reaches the host only through a switch counts as shipped once the host runs it. A failed
# switch leaves the tag where it was.
# The switch runs only after the build
# exits 0: a failed build stops the script before
# anything reaches the host. The build reads a `git archive` snapshot of the checked commit,
# not the working tree, so an edit made while the script runs changes nothing. The snapshot's
# root is the flake's source (path:.?dir=nixos), not nixos/ alone, because the host config reads
# the shared constants in packages/topology (nixos/topology.nix). The switch
# activates that build's exact store path: it copies the closure to the host, points the
# system profile at it and runs its switch-to-configuration, as nixos-rebuild does, with no
# second evaluation of the flake.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/nix-image.sh"

mode=switch
k3s_args=()
host="${GEOFFCLOUD_HOST:-root@geoffcloud}"

case "${1:-switch}" in
  switch) ;;
  --build-only) mode=--build-only ;;
  --allow-k3s-restart) k3s_args=(--allow-k3s-restart) ;;
  *)
    echo "usage: switch-geoffcloud.sh [--build-only | --allow-k3s-restart]" >&2
    exit 2
    ;;
esac

repo="$(git rev-parse --show-toplevel)"
snapshot="$(mktemp -d)"

# the archive sits beside the snapshot, so a failed `git archive` leaves no partial tar
teardown() {
  rm -rf "$snapshot" "$snapshot.tar"
}
trap teardown EXIT

# Sets verified_commit, the exact commit it checked; the build archives that value and never
# reads HEAD again. Each git result is a checked assignment, so a failing git stops the script (set -e)
# rather than reading as clean. Untracked files are allowed: the build reads only the
# commit's `git archive`, so nothing outside the commit can reach it.
require_clean_main() {
  local branch changes head upstream
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" != main ]]; then
    echo "switch from main, not $branch" >&2
    exit 1
  fi
  changes="$(git -C "$repo" status --porcelain --untracked-files=no)"
  if [[ -n "$changes" ]]; then
    echo "the checkout has uncommitted changes" >&2
    exit 1
  fi
  git -C "$repo" fetch -q origin main
  head="$(git -C "$repo" rev-parse HEAD)"
  upstream="$(git -C "$repo" rev-parse origin/main)"
  if [[ "$head" != "$upstream" ]]; then
    echo "main is not origin/main; pull first" >&2
    exit 1
  fi
  verified_commit="$head"
}

# The running atc gateway dials the host's atc daemon, so a switch takes only an atc daemon pin of
# the gateway's atc major (scripts/check-atc-gateway-skew.sh). It reads the gateway's pods, not its
# Deployment's spec: a rollout changes the spec first, and the old pod runs until it ends. It runs
# before the build and again before the activation, so a gateway rollout during the build or the
# copy cannot slip past. An ssh or kubectl failure stops the script (set -e) rather than reading
# as no skew.
require_gateway_major() {
  local images
  images="$(ssh -o BatchMode=yes "$host" \
    "k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'")"
  # kubectl's jsonpath joins the pods' images with spaces, and an image reference holds none
  # shellcheck disable=SC2086
  bash "$(dirname "${BASH_SOURCE[0]}")/check-atc-gateway-skew.sh" "$snapshot/nixos/packages/atc.nix" $images
}

# nixie refuses an impd of a major it does not accept, so a switch takes only an impd whose major
# each running nixie pod accepts (scripts/check-nixie-impd-major.sh). It reads the pods,
# runs at the same two points, and fails on an ssh, kubectl or gh failure, as the gateway check does.
require_nixie_impd_major() {
  local images
  images="$(ssh -o BatchMode=yes "$host" \
    "k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'")"
  # kubectl's jsonpath joins the pods' images with spaces, and an image reference holds none
  # shellcheck disable=SC2086
  bash "$(dirname "${BASH_SOURCE[0]}")/check-nixie-impd-major.sh" \
    "$snapshot/nixos/hosts/geoffcloud/configuration.nix" $images
}

# A k3s restart can keep nixie down for minutes, so the switch asks the copied system which units
# its activation would stop or restart, and holds when k3s.service is one of them
# (scripts/check-k3s-restart.sh). It runs switch-to-configuration dry-activate as nixos-rebuild
# dry-activate does (nix.py: switch_to_configuration), which changes nothing on the host and
# prints its lists on stderr. An ssh or dry-activate failure stops the script with its output and
# exit code rather than reading as no restart.
require_k3s_kept() {
  local plan status=0
  plan="$(ssh -o BatchMode=yes "$host" "NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE \
    -E NIXOS_INSTALL_BOOTLOADER -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet \
    --service-type=exec --unit=switch-geoffcloud-dry-activate '$built/bin/switch-to-configuration' \
    dry-activate" 2>&1)" || status=$?
  if [ "$status" != 0 ]; then
    printf '%s\n' "$plan" >&2
    exit "$status"
  fi
  bash "$(dirname "${BASH_SOURCE[0]}")/check-k3s-restart.sh" "${k3s_args[@]}" <<< "$plan"
}

verified_commit=""
require_clean_main
commit="$verified_commit"
git -C "$repo" archive -o "$snapshot.tar" "$commit"
tar -x -f "$snapshot.tar" -C "$snapshot"
rm -f "$snapshot.tar"

# The NixOS checks gate the switch, not the merge: a switch takes only a commit that a green run
# of the checks covers (scripts/find-nixos-check-run.sh). --build-only reaches no host, so it
# builds any commit. A gh failure stops the script (set -e) rather than reading as unchecked.
if [[ "$mode" == switch ]]; then
  checked_by="$(bash "$(dirname "${BASH_SOURCE[0]}")/find-nixos-check-run.sh" "$commit")"
  if [[ -z "$checked_by" ]]; then
    echo "no green NixOS checks run covers ${commit:0:7}; start one with" \
      "\`gh workflow run nixos-checks.yml --ref main\` and switch once it passes" >&2
    exit 1
  fi
  echo "== checked by $checked_by"
  require_gateway_major
  require_nixie_impd_major
  # both pins come from the snapshot, which the copy cannot change, so this check runs once
  bash "$(dirname "${BASH_SOURCE[0]}")/check-atc-secret-kinds.sh" \
    "$snapshot/nixos/hosts/geoffcloud/configuration.nix" "$snapshot/nixos/packages/atc.nix"
fi
echo "== build ${commit:0:7}"

# a failed build exits non-zero here, and set -e stops the script before the switch
built="$(docker run --rm --network host -v geoffcloud-nix-store:/nix -v "$snapshot":/src:ro -w /src \
  "$NIX_IMAGE" nix --extra-experimental-features "nix-command flakes" build --no-link \
  --print-out-paths path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel)"

if [[ ! "$built" =~ ^/nix/store/[a-z0-9]{32}-nixos-system-geoffcloud-[A-Za-z0-9._-]+$ ]]; then
  echo "the build printed no system path: $built" >&2
  exit 1
fi
echo "built $built"

if [[ "$mode" == --build-only ]]; then
  exit 0
fi

echo "== copy to $host"
docker run --rm --network host -v geoffcloud-nix-store:/nix \
  -v ~/.ssh/known_hosts:/root/.ssh/known_hosts:ro -e NIX_SSHOPTS="-o BatchMode=yes" \
  "$NIX_IMAGE" nix --extra-experimental-features "nix-command flakes" shell nixpkgs#openssh \
  -c nix --extra-experimental-features nix-command copy --to "ssh://$host" "$built"

require_k3s_kept

# as nixos-rebuild 26.11 (nix.py: set_profile, switch_to_configuration): the profile first, so a
# boot after a failed activation still picks the new system, then switch-to-configuration in its
# own unit, so it survives a dropped SSH. Between
# them it records which commit the system was built from, which the host's build lag check
# (nixos/modules/host-build-lag.sh) reads, because the store path does not hold the commit.
require_gateway_major
require_nixie_impd_major
echo "== switch $host"
ssh -o BatchMode=yes "$host" "nix-env -p /nix/var/nix/profiles/system --set '$built' \
  && mkdir -p /var/lib/host-build-lag && echo '$commit $built' >> /var/lib/host-build-lag/switches \
  && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER \
    -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet \
    --service-type=exec --unit=switch-geoffcloud '$built/bin/switch-to-configuration' switch"

current="$(ssh -o BatchMode=yes "$host" readlink /run/current-system)"
if [[ "$current" != "$built" ]]; then
  echo "the host runs $current, not the built $built" >&2
  exit 1
fi
echo "== $host runs $current"
ssh -o BatchMode=yes "$host" systemctl --failed --no-legend --plain
bash "$(dirname "${BASH_SOURCE[0]}")/check-nixie-ready.sh" "$host"
bash "$(dirname "${BASH_SOURCE[0]}")/check-impd-image-dirs.sh" "$host"
bash "$(dirname "${BASH_SOURCE[0]}")/check-hugetlb-pool.sh" "$host"

# The tag records the commit the host runs, and the last activation decides that, so the push forces
# the tag even when an earlier switch left it on a later commit. A failed push fails the switch with
# git's exit code and the command that moves the tag by hand, because the host runs the commit.
push_status=0
git -C "$repo" push -q --force origin "$commit:refs/tags/deployed/host" || push_status=$?
if [[ "$push_status" != 0 ]]; then
  echo "$host runs ${commit:0:7}, but deployed/host did not move; move it with" \
    "\`git push --force origin $commit:refs/tags/deployed/host\`" >&2
  exit "$push_status"
fi
echo "== deployed/host moved to $commit"
