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
# independently of build_token
it_builds_a_pinned_token_for_a_fixed_seed_and_label() {
  diff - <(build_token 1 good; echo) <<< 'imp_89f922fe941473d1.9bd8c757606732be9d362f27c45c79b05e376ddd9a8'
}

it_builds_a_token_in_imps_format() {
  [[ "$(build_token 42 good)" =~ ^imp_[0-9a-f]{16}\.[0-9a-f]{43}$ ]] || { echo "$(build_token 42 good) is not imp_<16>.<43>" >&2; exit 1; }
}

it_builds_the_same_token_for_the_same_seed_and_label() {
  [ "$(build_token 42 good)" = "$(build_token 42 good)" ]
}

it_builds_another_token_for_another_label() {
  [ "$(build_token 42 good)" != "$(build_token 42 stale)" ]
}

it_builds_another_token_for_another_seed() {
  [ "$(build_token 42 good)" != "$(build_token 43 good)" ]
}

run_cases
