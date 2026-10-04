#!/usr/bin/env bash
# Build geoffcloud's NixOS system from a clean checkout of main, then switch the host to it.
# Run it from the repo:
#
#   bash scripts/switch-geoffcloud.sh               # build, then switch
#   bash scripts/switch-geoffcloud.sh --build-only  # build and print the system path
#
# The switch runs only after the build exits 0: a failed build stops the script before
# anything reaches the host. The build uses `nix build --no-link`, because the repo mounts
# read-only and `nixos-rebuild build` writes a `result` link into it. After the switch, the
# host's current system must be the path this build printed, or the script fails.
set -euo pipefail

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

require_clean_main() {
  local branch
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" != main ]]; then
    echo "switch from main, not $branch" >&2
    exit 1
  fi
  if [[ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]]; then
    echo "the checkout has uncommitted changes" >&2
    exit 1
  fi
  git -C "$repo" fetch -q origin main
  if [[ "$(git -C "$repo" rev-parse HEAD)" != "$(git -C "$repo" rev-parse origin/main)" ]]; then
    echo "main is not origin/main; pull first" >&2
    exit 1
  fi
}

require_clean_main
echo "== build $(git -C "$repo" rev-parse --short HEAD)"

# a failed build exits non-zero here, and set -e stops the script before the switch
built="$(docker run --rm --network host -v geoffcloud-nix-store:/nix -v "$repo":/src:ro -w /src \
  nixos/nix nix --extra-experimental-features "nix-command flakes" build --no-link \
  --print-out-paths path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel)"

if [[ ! "$built" =~ ^/nix/store/[a-z0-9]{32}-nixos-system-geoffcloud-[^[:space:]]+$ ]]; then
  echo "the build printed no system path: $built" >&2
  exit 1
fi
echo "built $built"

if [[ "$mode" == --build-only ]]; then
  exit 0
fi

echo "== switch $host"
docker run --rm --network host -v geoffcloud-nix-store:/nix -v "$repo":/src:ro \
  -v ~/.ssh/known_hosts:/root/.ssh/known_hosts:ro -w /src -e NIX_SSHOPTS="-o BatchMode=yes" \
  nixos/nix sh -c "nix --extra-experimental-features 'nix-command flakes' \
    shell nixpkgs#openssh nixpkgs#nixos-rebuild -c nixos-rebuild switch \
    --flake path:./nixos#geoffcloud --target-host $host"

current="$(ssh -o BatchMode=yes "$host" readlink /run/current-system)"
if [[ "$current" != "$built" ]]; then
  echo "the host runs $current, not the built $built" >&2
  exit 1
fi
echo "== $host runs $current"
ssh -o BatchMode=yes "$host" systemctl --failed --no-legend --plain
