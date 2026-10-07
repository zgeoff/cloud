#!/usr/bin/env bash
# Build the NixOS flake's checks in a nixos/nix container, as scripts/switch-geoffcloud.sh builds
# the host, so you need no local Nix:
#
#   bash scripts/test-nixos.sh            # every check
#   bash scripts/test-nixos.sh atc-daemon # one check, by its name in checks.x86_64-linux
#
# impd-restore boots a NixOS VM, so it needs /dev/kvm. It reads scripts/ beside nixos/,
# so the build's flake source is the repo root (path:.?dir=nixos), not nixos/ alone. The source is
# a snapshot of the working tree's tracked and unignored files, so a local edit is tested before
# it is committed and nothing ignored, such as node_modules or .worktrees, is copied. The Docker
# volume NIX_STORE_VOLUME (default geoffcloud-nix-store) keeps the Nix store between runs.
set -euo pipefail

volume="${NIX_STORE_VOLUME:-geoffcloud-nix-store}"
if [ "$#" -gt 0 ]; then
  checks=("$@")
else
  checks=(atc-daemon impd-local-health impd-restore)
fi

# impd-restore's VM needs KVM; the other checks build without it
kvm=()
for check in "${checks[@]}"; do
  if [ "$check" = impd-restore ]; then
    if [ ! -c /dev/kvm ]; then
      echo "test-nixos: /dev/kvm is missing; impd-restore needs KVM" >&2
      exit 1
    fi
    kvm=(--device /dev/kvm)
  fi
done

repo="$(git rev-parse --show-toplevel)"
snapshot="$(mktemp -d)"

teardown() {
  rm -rf "$snapshot"
}
trap teardown EXIT

# tracked files that still exist, and untracked ones git does not ignore
git -C "$repo" ls-files -z --cached --others --exclude-standard --deduplicate |
  while IFS= read -r -d '' file; do
    if [ -e "$repo/$file" ] || [ -L "$repo/$file" ]; then
      printf '%s\0' "$file"
    fi
  done |
  tar -C "$repo" --null -T - -cf - | tar -C "$snapshot" -xf -

installables=()
for check in "${checks[@]}"; do
  installables+=("path:/src?dir=nixos#checks.x86_64-linux.$check")
done

docker run --rm --network host "${kvm[@]}" -v "$volume":/nix -v "$snapshot":/src:ro -w /src \
  nixos/nix nix --extra-experimental-features "nix-command flakes" \
  --option system-features "kvm nixos-test benchmark big-parallel uid-range" \
  build --no-link -L "${installables[@]}"
