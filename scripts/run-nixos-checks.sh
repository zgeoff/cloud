#!/usr/bin/env bash
# Build the NixOS flake's checks in the pinned Nix image (scripts/nix-image.sh), as
# scripts/switch-geoffcloud.sh builds the host, so you need no local Nix:
#
#   bash scripts/run-nixos-checks.sh            # every check in checks.x86_64-linux
#   bash scripts/run-nixos-checks.sh atc-daemon # one check, by its name there
#   bash scripts/run-nixos-checks.sh --derivations <file> [check…]
#   bash scripts/run-nixos-checks.sh --from-derivations <file>
#
# --derivations evaluates the checks and writes their derivation paths to <file>, sorted, one per
# line, and builds nothing, so it needs no KVM. --from-derivations builds the derivations such a
# file lists, from the store volume that evaluated them, without evaluating the flake again; it
# needs KVM, since it cannot tell which derivation boots a VM. NIXOS_CHECKS_CACHE names a local binary cache
# (scripts/write-nixos-checks-cache.sh writes one): when it holds a nix-cache-info, the build
# substitutes from it, unsigned, before it builds a path itself.
#
# impd-restore, every other check named impd-restore-*, tank-cloud-unlock, tank-cloud-host-secrets,
# tank-cloud-rancher, imp-dataset-key, geoffcloud-no-pool, network-policy, imp-cpu-weight,
# host-cgroup-cpu-vm, drift-check-vm, public-front-vm and atc-daemon-vm boot a NixOS VM, so they
# need KVM: unless /dev/kvm (or KVM_DEVICE, which the script's own test sets) is readable and
# writable, the script builds every other check it was asked for and then fails, naming those
# checks. Each such
# check itself fails if QEMU still falls back to emulation. A container for each check evaluates it to
# its derivation, and one more builds those derivations from the store. The checks read
# test-support/shell beside nixos/, so the evaluation's flake source is the repo root
# (path:.?dir=nixos), not nixos/ alone. The source is a snapshot of the working tree's
# tracked and unignored files, so a local edit is tested before it is committed and nothing
# ignored, such as node_modules or .worktrees, is copied. The Docker
# volume NIX_STORE_VOLUME (default cloud-nixos-checks-store) keeps the Nix store between runs; it
# is not the switch's geoffcloud-nix-store, so a test build never shares the deploy cache.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/nix-image.sh"

usage="usage: run-nixos-checks.sh [--derivations <file>] [check…] | --from-derivations <file>"
derivations_out=""
derivations_in=""
case "${1:-}" in
  --derivations)
    if [ -z "${2:-}" ]; then
      echo "$usage" >&2
      exit 2
    fi
    derivations_out="$2"
    shift 2
    ;;
  --from-derivations)
    if [ "$#" -ne 2 ] || [ ! -s "$2" ]; then
      echo "$usage" >&2
      exit 2
    fi
    derivations_in="$2"
    shift 2
    ;;
esac

volume="${NIX_STORE_VOLUME:-cloud-nixos-checks-store}"
kvm_device="${KVM_DEVICE:-/dev/kvm}"

# NIXOS_CHECKS_CPUS (a docker --cpuset-cpus list, such as 0-1) and NIXOS_CHECKS_MEMORY (a docker
# size, such as 7g, with swap off) cap the Nix container, so a bigger runner can prove the checks
# fit a smaller one; CI sets them to a 2 CPU / 8 GB runner's share
limits=()
if [ -n "${NIXOS_CHECKS_CPUS:-}" ]; then
  limits+=(--cpuset-cpus "$NIXOS_CHECKS_CPUS")
fi
if [ -n "${NIXOS_CHECKS_MEMORY:-}" ]; then
  limits+=(--memory "$NIXOS_CHECKS_MEMORY" --memory-swap "$NIXOS_CHECKS_MEMORY")
fi

run_nix() {
  docker run --rm --network host "${limits[@]}" "$@"
}

nix_args=(--extra-experimental-features "nix-command flakes")

# build_derivations <file> [docker option…]: builds every derivation the file lists, two at a time:
# each restore rehearsal boots a 2048 MB VM, so two of them fit in 7 GB beside Nix, where all four
# would not. The cache's directory is mounted writable, because nix creates its missing folders on
# open.
build_derivations() {
  local list="$1" cache=() outputs
  shift
  if [ -n "${NIXOS_CHECKS_CACHE:-}" ] && [ -f "$NIXOS_CHECKS_CACHE/nix-cache-info" ]; then
    cache=(-v "$NIXOS_CHECKS_CACHE":/cache)
    nix_args+=(--option extra-substituters 'file:///cache?trusted=true')
  fi
  mapfile -t outputs < <(sed 's/$/^*/' "$list")
  run_nix "$@" "${cache[@]}" -v "$volume":/nix "$NIX_IMAGE" \
    nix "${nix_args[@]}" --option system-features "kvm nixos-test benchmark big-parallel uid-range" \
    --max-jobs 2 build --no-link -L "${outputs[@]}"
}

if [ -n "$derivations_in" ]; then
  if [ ! -r "$kvm_device" ] || [ ! -w "$kvm_device" ]; then
    echo "run-nixos-checks: $kvm_device is missing or not readable and writable; --from-derivations needs KVM" >&2
    exit 1
  fi
  build_derivations "$derivations_in" --device "$kvm_device:/dev/kvm"
  exit 0
fi

repo="$(git rev-parse --show-toplevel)"
snapshot="$(mktemp -d)"
derivations="$(mktemp)"

teardown() {
  rm -rf "$snapshot" "$derivations"
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

if [ "$#" -gt 0 ]; then
  checks=("$@")
else
  # every check the flake declares, so a new one cannot be left out of the default run
  # written to a file first, so a failing eval stops the script instead of building nothing
  names="$(mktemp)"
  trap 'teardown; rm -f "$names"' EXIT
  run_nix -v "$volume":/nix -v "$snapshot":/src:ro -w /src "$NIX_IMAGE" \
    nix "${nix_args[@]}" eval --raw "path:/src?dir=nixos#checks.x86_64-linux" \
    --apply 'checks: builtins.concatStringsSep "\n" (builtins.attrNames checks) + "\n"' > "$names"
  # an empty set of checks evaluates to one empty line, which names no check
  mapfile -t checks < <(sed '/^$/d' "$names")
  if [ "${#checks[@]}" -eq 0 ]; then
    echo "run-nixos-checks: the flake declares no checks.x86_64-linux" >&2
    exit 1
  fi
fi

# the restore rehearsals' VMs need KVM; the other checks build without it
kvm=()
missing_kvm=()
installables=()
for check in "${checks[@]}"; do
  case "$check" in
    impd-restore | impd-restore-* | tank-cloud-unlock | tank-cloud-host-secrets | tank-cloud-rancher | \
      imp-dataset-key | geoffcloud-no-pool | network-policy | imp-cpu-weight | host-cgroup-cpu-vm | \
      drift-check-vm | public-front-vm | atc-daemon-vm)
      # QEMU opens the device read-write, and falls back to emulation when it cannot; an
      # evaluation alone needs no KVM
      if [ -z "$derivations_out" ] && { [ ! -r "$kvm_device" ] || [ ! -w "$kvm_device" ]; }; then
        missing_kvm+=("$check")
        continue
      fi
      kvm=(--device "$kvm_device:/dev/kvm")
      ;;
  esac
  installables+=("path:/src?dir=nixos#checks.x86_64-linux.$check")
done

# each check is evaluated to its derivation in a container of its own, and the derivations are
# built in another: a nix keeps the heap of everything it evaluated until it exits, and one that
# evaluated every check held about 5.5 GB. As the build's nix, it left the VMs too little of the
# 7 GB cap, and the kernel killed it (GEO-937); even alone, it reached the cap. One check's heap
# is far smaller, and the build's nix reads only the store.
if [ "${#installables[@]}" -gt 0 ]; then
  for installable in "${installables[@]}"; do
    run_nix -v "$volume":/nix -v "$snapshot":/src:ro -w /src "$NIX_IMAGE" \
      nix "${nix_args[@]}" path-info --derivation "$installable" >> "$derivations"
  done
  if [ -n "$derivations_out" ]; then
    LC_ALL=C sort "$derivations" > "$derivations_out"
    exit 0
  fi
  build_derivations "$derivations" "${kvm[@]}"
fi

if [ "${#missing_kvm[@]}" -eq 1 ]; then
  echo "run-nixos-checks: $kvm_device is missing or not readable and writable; ${missing_kvm[0]} needs KVM" >&2
  exit 1
elif [ "${#missing_kvm[@]}" -gt 1 ]; then
  kvm_checks="$(printf '%s, ' "${missing_kvm[@]}")"
  echo "run-nixos-checks: $kvm_device is missing or not readable and writable; ${kvm_checks%, } need KVM" >&2
  exit 1
fi
