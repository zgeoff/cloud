#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for scripts/nix-image.sh: the pin names the Nix image by tag and digest, both
# scripts that run Nix read it from there, and every other image reference under scripts/
# is that same pin, so CI's NixOS checks and a host switch build with the same Nix. It runs
# no container: it sources the pin and greps the working tree. The search pattern spells the
# image with a bracket, so this file's own pattern stays out of its scan.
#
#   bash scripts/run-bats.sh
#   CASE='tag and digest' bash scripts/run-bats.sh   # the cases whose title holds it

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'nix-image.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

@test "it pins the nix image by tag and digest" {
  [[ "$NIX_IMAGE" =~ ^[a-z]+/[a-z]+:[A-Za-z0-9_.-]+@sha256:[0-9a-f]{64}$ ]] ||
    {
      echo "bad Nix image pin: $NIX_IMAGE" >&2
      exit 1
    }
}

@test "it is the one source both nix scripts read" {
  root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  for script in run-nixos-checks.sh switch-geoffcloud.sh; do
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

@test "it leaves no bare image reference under scripts" {
  root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  grep -rn '[n]ixos/nix' "$root/scripts" > "$tree/refs"
  grep -v "^$root/scripts/nix-image\.sh:" "$tree/refs" > "$tree/other" || true
  grep -v -F "$NIX_IMAGE" "$tree/other" > "$tree/bare" || true
  run -0 diff /dev/null "$tree/bare"
}
