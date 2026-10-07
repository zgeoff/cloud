#!/usr/bin/env bash
# Build the NixOS flake's checks in a nixos/nix container, as scripts/switch-geoffcloud.sh builds
# the host, so you need no local Nix:
#
#   bash scripts/test-nixos.sh            # every check in checks.x86_64-linux
#   bash scripts/test-nixos.sh atc-daemon # one check, by its name there
#
# impd-restore boots a NixOS VM, so it needs /dev/kvm: without it, the script builds every other
# check it was asked for and then fails, naming impd-restore. It reads scripts/ beside nixos/,
# so the build's flake source is the repo root (path:.?dir=nixos), not nixos/ alone. The source is
# a snapshot of the working tree's tracked and unignored files, so a local edit is tested before
# it is committed and nothing ignored, such as node_modules or .worktrees, is copied. The Docker
# volume NIX_STORE_VOLUME (default cloud-nixos-checks-store) keeps the Nix store between runs; it
# is not the switch's geoffcloud-nix-store, so a test build never shares the deploy cache.
set -euo pipefail

volume="${NIX_STORE_VOLUME:-cloud-nixos-checks-store}"
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

run_nix() {
  docker run --rm --network host "$@"
}

nix_args=(--extra-experimental-features "nix-command flakes")
if [ "$#" -gt 0 ]; then
  checks=("$@")
else
  # every check the flake declares, so a new one cannot be left out of the default run
  # written to a file first, so a failing eval stops the script instead of building nothing
  names="$(mktemp)"
  trap 'teardown; rm -f "$names"' EXIT
  run_nix -v "$volume":/nix -v "$snapshot":/src:ro -w /src nixos/nix \
    nix "${nix_args[@]}" eval --raw "path:/src?dir=nixos#checks.x86_64-linux" \
    --apply 'checks: builtins.concatStringsSep "\n" (builtins.attrNames checks) + "\n"' > "$names"
  mapfile -t checks < "$names"
  if [ "${#checks[@]}" -eq 0 ]; then
    echo "test-nixos: the flake declares no checks.x86_64-linux" >&2
    exit 1
  fi
fi

# impd-restore's VM needs KVM; the other checks build without it
kvm=()
missing_kvm=""
installables=()
for check in "${checks[@]}"; do
  if [ "$check" = impd-restore ]; then
    if [ ! -c /dev/kvm ]; then
      missing_kvm=1
      continue
    fi
    kvm=(--device /dev/kvm)
  fi
  installables+=("path:/src?dir=nixos#checks.x86_64-linux.$check")
done

if [ "${#installables[@]}" -gt 0 ]; then
  run_nix "${kvm[@]}" -v "$volume":/nix -v "$snapshot":/src:ro -w /src nixos/nix \
    nix "${nix_args[@]}" --option system-features "kvm nixos-test benchmark big-parallel uid-range" \
    build --no-link -L "${installables[@]}"
fi

if [ -n "$missing_kvm" ]; then
  echo "test-nixos: /dev/kvm is missing; impd-restore needs KVM" >&2
  exit 1
fi
