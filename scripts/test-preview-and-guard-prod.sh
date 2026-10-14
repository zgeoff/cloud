#!/usr/bin/env bash
# Test for preview-and-guard-prod.sh: with a bun stand-in (test-support/shell/create-stub-prod-apply-bun.sh)
# answering the SDK build, the preview and the guard, it builds the SDK, previews into the
# runner's plan file, runs the guard on that file and the drift outcome, shows the guard's text on
# stdout and in the step summary, and writes verdict=apply or verdict=hold; it fails after showing
# the guard's text when the preview fails, fails with no verdict on any other guard status, stops
# before the preview when the SDK build fails, and refuses a missing variable. Each case runs the
# script under `env -i` and compares its whole stdout, stderr, step output, step summary, plan
# file and bun call log.
#
#   bash scripts/test-preview-and-guard-prod.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-prod-apply-bun.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preview-and-guard-prod.sh"

it_passes_the_plan_with_verdict_apply_and_shows_the_guard_s_text() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_PLAN='{"steps":[{"op":"same"}]}' STUB_GUARD='The guard passes the plan: no held step.' \
    RUNNER_TEMP="$tree/runner" DRIFT=success GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'The guard passes the plan: no held step.'
  diff - "$tree/err" <<< '$ tsc -p sdk/onidel/tsconfig.json && cp sdk/onidel/package.json sdk/onidel/bin/package.json'
  diff - "$tree/output" <<< 'verdict=apply'
  diff - "$tree/summary" <<< 'The guard passes the plan: no held step.'
  diff - "$tree/runner/plan.json" <<< '{"steps":[{"op":"same"}]}'
  diff - "$tree/calls" << EOF
{"cwd":"$tree/repo","argv":["bun","run","sdk:build"]}
{"cwd":"$tree/repo","argv":["bun","run","--silent","preview","--","--refresh","--json"]}
{"cwd":"$tree/repo","argv":["bun","run","--silent","ci:check-prod-plan","$tree/runner/plan.json","success"]}
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_holds_the_plan_with_verdict_hold_when_the_guard_exits_3() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_PLAN='{"steps":[{"op":"replace"}]}' STUB_GUARD='Held: the drift check failed.' STUB_GUARD_EXIT=3 \
    RUNNER_TEMP="$tree/runner" DRIFT=failure GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'Held: the drift check failed.'
  diff - "$tree/err" <<< '$ tsc -p sdk/onidel/tsconfig.json && cp sdk/onidel/package.json sdk/onidel/bin/package.json'
  diff - "$tree/output" <<< 'verdict=hold'
  diff - "$tree/summary" <<< 'Held: the drift check failed.'
  diff - "$tree/runner/plan.json" <<< '{"steps":[{"op":"replace"}]}'
  diff - "$tree/calls" << EOF
{"cwd":"$tree/repo","argv":["bun","run","sdk:build"]}
{"cwd":"$tree/repo","argv":["bun","run","--silent","preview","--","--refresh","--json"]}
{"cwd":"$tree/repo","argv":["bun","run","--silent","ci:check-prod-plan","$tree/runner/plan.json","failure"]}
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_shows_the_guard_s_text_then_fails_naming_the_preview_s_status_when_the_preview_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_PREVIEW_EXIT=255 STUB_GUARD='The plan is not JSON.' STUB_GUARD_EXIT=1 \
    RUNNER_TEMP="$tree/runner" DRIFT=success GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'The plan is not JSON.'
  diff - "$tree/err" << 'EOF'
$ tsc -p sdk/onidel/tsconfig.json && cp sdk/onidel/package.json sdk/onidel/bin/package.json
the preview failed (exit 255)
EOF
  diff /dev/null "$tree/output"
  diff - "$tree/summary" <<< 'The plan is not JSON.'
  diff /dev/null "$tree/runner/plan.json"
  diff - "$tree/calls" << EOF
{"cwd":"$tree/repo","argv":["bun","run","sdk:build"]}
{"cwd":"$tree/repo","argv":["bun","run","--silent","preview","--","--refresh","--json"]}
{"cwd":"$tree/repo","argv":["bun","run","--silent","ci:check-prod-plan","$tree/runner/plan.json","success"]}
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_with_no_verdict_when_the_guard_fails_with_any_other_status() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_PLAN='{"steps":[]}' STUB_GUARD='usage: check-prod-plan.ts <plan> <drift outcome>' STUB_GUARD_EXIT=2 \
    RUNNER_TEMP="$tree/runner" DRIFT=success GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'usage: check-prod-plan.ts <plan> <drift outcome>'
  diff - "$tree/err" <<< '$ tsc -p sdk/onidel/tsconfig.json && cp sdk/onidel/package.json sdk/onidel/bin/package.json'
  diff /dev/null "$tree/output"
  diff - "$tree/summary" <<< 'usage: check-prod-plan.ts <plan> <drift outcome>'
  diff - "$tree/calls" << EOF
{"cwd":"$tree/repo","argv":["bun","run","sdk:build"]}
{"cwd":"$tree/repo","argv":["bun","run","--silent","preview","--","--refresh","--json"]}
{"cwd":"$tree/repo","argv":["bun","run","--silent","ci:check-prod-plan","$tree/runner/plan.json","success"]}
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_stops_before_the_preview_with_the_sdk_build_s_status_when_the_build_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SDK_BUILD_EXIT=2 \
    RUNNER_TEMP="$tree/runner" DRIFT=success GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
$ tsc -p sdk/onidel/tsconfig.json && cp sdk/onidel/package.json sdk/onidel/bin/package.json
error: script "sdk:build" exited with code 2
EOF
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  [ ! -e "$tree/runner/plan.json" ] || {
    echo "the script wrote $tree/runner/plan.json" >&2
    exit 1
  }
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"run\",\"sdk:build\"]}"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_refuses_to_run_without_the_drift_outcome() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    RUNNER_TEMP="$tree/runner" GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'preview-and-guard-prod: set DRIFT'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo" "$tree/runner"
  : > "$tree/calls"
  : > "$tree/output"
  : > "$tree/summary"
  create_stub_prod_apply_bun "$tree/bin"
}

run_cases
