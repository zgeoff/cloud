#!/usr/bin/env bash
# Build geoffcloud's NixOS system from a clean checkout of main, then switch the host to it.
# Run it from the repo:
#
#   bash scripts/switch-geoffcloud.sh               # build, then switch
#   bash scripts/switch-geoffcloud.sh --build-only  # build and print the system path
#
# A switch first needs a green NixOS checks run that covers the commit; with none, it stops
# before the build and names the command that starts one. The switch runs only after the build
# exits 0: a failed build stops the script before
# anything reaches the host. The build reads a `git archive` snapshot of the checked commit,
# not the working tree, so an edit made while the script runs changes nothing. The switch
# activates that build's exact store path: it copies the closure to the host, points the
# system profile at it and runs its switch-to-configuration, as nixos-rebuild does, with no
# second evaluation of the flake.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/nix-image.sh"

mode="${1:-switch}"
host="${GEOFFCLOUD_HOST:-root@geoffcloud}"

case "$mode" in
  switch | --build-only) ;;
  *)
    echo "usage: switch-geoffcloud.sh [--build-only]" >&2
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
fi
echo "== build ${commit:0:7}"

# a failed build exits non-zero here, and set -e stops the script before the switch
built="$(docker run --rm --network host -v geoffcloud-nix-store:/nix -v "$snapshot":/src:ro -w /src \
  "$NIX_IMAGE" nix --extra-experimental-features "nix-command flakes" build --no-link \
  --print-out-paths path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel)"

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

# as nixos-rebuild 26.11 (nix.py: set_profile, switch_to_configuration): the profile first, so a boot after a failed activation still picks the
# new system, then switch-to-configuration in its own unit, so it survives a dropped SSH
echo "== switch $host"
ssh -o BatchMode=yes "$host" "nix-env -p /nix/var/nix/profiles/system --set '$built' \
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
