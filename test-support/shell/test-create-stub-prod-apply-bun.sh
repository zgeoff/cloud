#!/usr/bin/env bash
# Test for create-stub-prod-apply-bun.sh: the bun stand-in answers the install, the SDK build, the
# preview and the guard that the prod apply job's scripts run, with the output and exit status
# each case sets, echoes the SDK build's script line as bun does (the line the root package.json
# holds), logs every call with its working directory, and fails closed on any other call.
#
#   bash test-support/shell/test-create-stub-prod-apply-bun.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-prod-apply-bun.sh"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

it_answers_an_install_with_exit_0_and_logs_the_directory_it_ran_in() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/work"

  (cd "$tree/work" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bun install --frozen-lockfile) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/work\",\"argv\":[\"bun\",\"install\",\"--frozen-lockfile\"]}"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_an_install_with_the_exit_the_case_sets() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_INSTALL_EXIT=1 bun install --frozen-lockfile) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"install\",\"--frozen-lockfile\"]}"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_echoes_the_sdk_build_script_line_that_the_root_package_json_holds() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  jq -r '"$ " + .scripts["sdk:build"]' "$root/package.json" > "$tree/want"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bun run sdk:build) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff "$tree/want" "$tree/err"
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"run\",\"sdk:build\"]}"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_the_sdk_build_with_bun_s_error_line_and_the_exit_the_case_sets() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SDK_BUILD_EXIT=2 bun run sdk:build) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
$ tsc -p sdk/onidel/tsconfig.json && cp sdk/onidel/package.json sdk/onidel/bin/package.json
error: script "sdk:build" exited with code 2
EOF
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"run\",\"sdk:build\"]}"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_prints_the_plan_for_the_preview_and_exits_with_the_status_the_case_sets() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_PLAN='{"steps":[]}' STUB_PREVIEW_EXIT=255 bun run --silent preview -- --refresh --json) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '{"steps":[]}'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"run\",\"--silent\",\"preview\",\"--\",\"--refresh\",\"--json\"]}"
  [ "$status" = 255 ] || {
    echo "exit $status, want 255" >&2
    exit 1
  }
}

it_prints_the_guard_text_and_exits_with_the_status_the_case_sets() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_GUARD='held: replace urn:a' STUB_GUARD_EXIT=3 bun run --silent ci:check-prod-plan /tmp/plan.json failure) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'held: replace urn:a'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"run\",\"--silent\",\"ci:check-prod-plan\",\"/tmp/plan.json\",\"failure\"]}"
  [ "$status" = 3 ] || {
    echo "exit $status, want 3" >&2
    exit 1
  }
}

it_fails_closed_with_exit_97_on_a_guard_call_without_its_two_arguments() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bun run --silent ci:check-prod-plan /tmp/plan.json) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: run --silent ci:check-prod-plan /tmp/plan.json'
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"run\",\"--silent\",\"ci:check-prod-plan\",\"/tmp/plan.json\"]}"
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bun run preview -- --refresh --json) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: run preview -- --refresh --json'
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"run\",\"preview\",\"--\",\"--refresh\",\"--json\"]}"
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_prod_apply_bun "$tree/bin"
}

run_cases
