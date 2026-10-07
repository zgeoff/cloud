#!/usr/bin/env bash
# Test for build-token.sh: build_token makes an imp-format token from a seed and a label
# alone.
#
#   bash scripts/test-lib/test-build-token.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/build-token.sh"

# the value is sha256("1-good-id")[:16] and sha256("1-good-secret")[:43], derived
# independently of build_token; it ends without a newline
it_builds_a_pinned_token_for_a_fixed_seed_and_label() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  build_token 1 good > "$tree/token"

  printf '%s' 'imp_89f922fe941473d1.9bd8c757606732be9d362f27c45c79b05e376ddd9a8' | cmp - "$tree/token"
}

it_builds_a_token_in_imps_format() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  build_token 42 good > "$tree/token"

  [[ "$(< "$tree/token")" =~ ^imp_[0-9a-f]{16}\.[0-9a-f]{43}$ ]] || { echo "$(< "$tree/token") is not imp_<16>.<43>" >&2; exit 1; }
}

it_builds_the_same_token_for_the_same_seed_and_label() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  build_token 42 good > "$tree/first"
  build_token 42 good > "$tree/second"

  cmp "$tree/first" "$tree/second"
}

it_builds_another_token_for_another_label() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  build_token 42 good > "$tree/good"
  build_token 42 stale > "$tree/stale"

  ! cmp -s "$tree/good" "$tree/stale" || { echo "both labels built $(< "$tree/good")" >&2; exit 1; }
}

it_builds_another_token_for_another_seed() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  build_token 42 good > "$tree/seed-42"
  build_token 43 good > "$tree/seed-43"

  ! cmp -s "$tree/seed-42" "$tree/seed-43" || { echo "both seeds built $(< "$tree/seed-42")" >&2; exit 1; }
}

run_cases
