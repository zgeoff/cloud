#!/usr/bin/env bash
# Test for scripts/nix-image.sh: the pin names the Nix image by tag and digest, both
# scripts that run Nix read it from there, and every other image reference under scripts/
# is that same pin, so CI's NixOS checks and a host switch build with the same Nix. It runs
# no container: it sources the pin and greps the working tree. The search pattern spells the
# image with a bracket, so this file's own pattern stays out of its scan.
#
#   bash scripts/test-nix-image.sh
#   CASE='tag and digest' bash scripts/test-nix-image.sh   # the cases whose title holds it
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/nix-image.sh"

it_pins_the_nix_image_by_tag_and_digest() {
  [[ "$NIX_IMAGE" =~ ^[a-z]+/[a-z]+:[A-Za-z0-9_.-]+@sha256:[0-9a-f]{64}$ ]] ||
    {
      echo "bad Nix image pin: $NIX_IMAGE" >&2
      exit 1
    }
}

it_is_the_one_source_both_nix_scripts_read() {
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  for script in test-nixos.sh switch-geoffcloud.sh; do
    grep -q 'source .*/nix-image\.sh' "$root/scripts/$script" ||
      {
        echo "scripts/$script does not source nix-image.sh" >&2
        exit 1
      }
    if grep -q '[n]ixos/nix' "$root/scripts/$script"; then
      echo "scripts/$script names the image instead of reading the pin" >&2
      exit 1
    fi
  done
}

it_leaves_no_bare_image_reference_under_scripts() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  grep -rn '[n]ixos/nix' "$root/scripts" > "$tree/refs"
  grep -v "^$root/scripts/nix-image\.sh:" "$tree/refs" > "$tree/other" || true
  grep -v -F "$NIX_IMAGE" "$tree/other" > "$tree/bare" || true
  diff /dev/null "$tree/bare"
}

run_cases
