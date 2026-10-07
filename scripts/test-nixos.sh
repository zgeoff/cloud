#!/usr/bin/env bash
# Build the NixOS flake's checks in a nixos/nix container, as scripts/switch-geoffcloud.sh builds
# the host, so you need no local Nix:
#
#   bash scripts/test-nixos.sh            # every check in checks.x86_64-linux
#   bash scripts/test-nixos.sh atc-daemon # one check, by its name there
#
# impd-restore and every other check named impd-restore-* boot a NixOS VM, so they need KVM:
# unless /dev/kvm (or KVM_DEVICE, which the script's own test sets) is readable and writable, the
# script builds every other check it was asked for and then fails, naming those checks. Each such
# check itself fails if QEMU still falls back to emulation. The checks read scripts/ beside nixos/ (scripts/test-lib, and the scripts they
# test), so the build's flake source is the repo root (path:.?dir=nixos), not nixos/ alone. The
# source is a snapshot of the working tree's tracked and unignored files, so a local edit is tested before
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
  # an empty set of checks evaluates to one empty line, which names no check
  mapfile -t checks < <(sed '/^$/d' "$names")
  if [ "${#checks[@]}" -eq 0 ]; then
    echo "test-nixos: the flake declares no checks.x86_64-linux" >&2
    exit 1
  fi
fi

# the restore rehearsals' VMs need KVM; the other checks build without it
kvm_device="${KVM_DEVICE:-/dev/kvm}"
kvm=()
missing_kvm=()
installables=()
for check in "${checks[@]}"; do
  case "$check" in
    impd-restore | impd-restore-*)
      # QEMU opens the device read-write, and falls back to emulation when it cannot
      if [ ! -r "$kvm_device" ] || [ ! -w "$kvm_device" ]; then
        missing_kvm+=("$check")
        continue
      fi
      kvm=(--device "$kvm_device:/dev/kvm")
      ;;
  esac
  installables+=("path:/src?dir=nixos#checks.x86_64-linux.$check")
done

if [ "${#installables[@]}" -gt 0 ]; then
  run_nix "${kvm[@]}" -v "$volume":/nix -v "$snapshot":/src:ro -w /src nixos/nix \
    nix "${nix_args[@]}" --option system-features "kvm nixos-test benchmark big-parallel uid-range" \
    build --no-link -L "${installables[@]}"
fi

if [ "${#missing_kvm[@]}" -eq 1 ]; then
  echo "test-nixos: $kvm_device is missing or not readable and writable; ${missing_kvm[0]} needs KVM" >&2
  exit 1
elif [ "${#missing_kvm[@]}" -gt 1 ]; then
  names="$(printf '%s, ' "${missing_kvm[@]}")"
  echo "test-nixos: $kvm_device is missing or not readable and writable; ${names%, } need KVM" >&2
  exit 1
fi
