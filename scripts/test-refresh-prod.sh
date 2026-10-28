#!/usr/bin/env bash
# Test for refresh-prod.sh: with stand-ins for bun and op (create-stub-scripted-command.sh) and the
# real retry-transient-pulumi.sh, it builds the provider in the program checkout and runs
# `op run --env-file=../.env -- pulumi refresh --stack prod --yes --skip-preview --suppress-outputs`
# in its infra/, runs the refresh again after a pause when it fails on a Cloudflare API 502 to a
# GET, stops before the refresh when the provider build fails, and refuses a missing PROGRAM. The
# pause is create-stub-clock.sh's sleep, first on PATH, which records each pause. Each case runs the
# script under `env -i` and compares its whole stdout, stderr, call logs and pauses.
#
#   bash scripts/test-refresh-prod.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-clock.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-scripted-command.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/refresh-prod.sh"

it_builds_the_provider_then_refreshes_the_prod_stack_in_infra() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo 0 > "$tree/bun-answers/1.status"
  printf 'Resources:\n    80 unchanged\n' > "$tree/op-answers/1.out"

  (cd "$tree/repo" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    PROGRAM=program bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOT'
Resources:
    80 unchanged
EOT
  diff /dev/null "$tree/err"
  diff - "$tree/bun-calls" <<< "{\"cwd\":\"$tree/repo/program\",\"argv\":[\"bun\",\"run\",\"provider:build\"]}"
  diff - "$tree/op-calls" <<< "{\"cwd\":\"$tree/repo/program/infra\",\"argv\":[\"op\",\"run\",\"--env-file=../.env\",\"--\",\"pulumi\",\"refresh\",\"--stack\",\"prod\",\"--yes\",\"--skip-preview\",\"--suppress-outputs\"]}"
  [ ! -e "$tree/clock/pauses" ] || {
    echo "it paused: $(cat "$tree/clock/pauses")" >&2
    exit 1
  }
  assert_status 0 "$status"
}

it_refreshes_again_after_a_cloudflare_api_502_to_a_get() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo 0 > "$tree/bun-answers/1.status"
  printf '%s\n' '    error: failed to make http request: GET "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/apps/5f6e7d8c": 502 Bad Gateway' > "$tree/op-answers/1.err"
  echo 255 > "$tree/op-answers/1.status"
  printf 'Resources:\n    80 unchanged\n' > "$tree/op-answers/2.out"

  (cd "$tree/repo" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    PROGRAM=program bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOT'
    error: failed to make http request: GET "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/apps/5f6e7d8c": 502 Bad Gateway
Resources:
    80 unchanged
EOT
  diff - "$tree/err" <<< 'retry-transient-pulumi: try 1 of 3 failed (exit 255) on an error a later try can pass; trying again in 60s'
  diff - "$tree/bun-calls" <<< "{\"cwd\":\"$tree/repo/program\",\"argv\":[\"bun\",\"run\",\"provider:build\"]}"
  diff - "$tree/op-calls" << EOT
{"cwd":"$tree/repo/program/infra","argv":["op","run","--env-file=../.env","--","pulumi","refresh","--stack","prod","--yes","--skip-preview","--suppress-outputs"]}
{"cwd":"$tree/repo/program/infra","argv":["op","run","--env-file=../.env","--","pulumi","refresh","--stack","prod","--yes","--skip-preview","--suppress-outputs"]}
EOT
  diff - "$tree/clock/pauses" <<< '60'
  assert_status 0 "$status"
}

it_stops_before_the_refresh_with_the_build_s_status_when_the_provider_build_fails() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'go: build failed\n' > "$tree/bun-answers/1.err"
  echo 4 > "$tree/bun-answers/1.status"

  (cd "$tree/repo" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    PROGRAM=program bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'go: build failed'
  diff /dev/null "$tree/op-calls"
  assert_status 4 "$status"
}

it_refuses_a_missing_program() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'refresh-prod: set PROGRAM'
  diff /dev/null "$tree/bun-calls"
  diff /dev/null "$tree/op-calls"
  assert_status 2 "$status"
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/clock" "$tree/home" "$tree/tmp" "$tree/repo/program/infra" \
    "$tree/bun-answers" "$tree/op-answers"
  : > "$tree/bun-calls"
  : > "$tree/op-calls"
  create_stub_clock "$tree/clock"
  create_stub_scripted_command "$tree/bin" bun "$tree/bun-calls" "$tree/bun-answers"
  create_stub_scripted_command "$tree/bin" op "$tree/op-calls" "$tree/op-answers"
}

run_cases
