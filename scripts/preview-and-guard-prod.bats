#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for preview-and-guard-prod.sh: with a bun stand-in (scripts/src/test-utils/shell/create-stub-prod-apply-bun.sh)
# answering the SDK build, the preview and the guard, it builds the SDK and previews into the
# runner's plan file in the program checkout, runs the guard from its own checkout on that file and the drift outcome, shows the guard's text on
# stdout and in the step summary, and writes verdict=apply or verdict=hold; it fails after showing
# the guard's text when the preview fails, fails with no verdict on any other guard status, stops
# before the preview when the SDK build fails, and refuses a missing variable. Each case runs the
# script under `env -i` and compares its whole stdout, stderr, step output, step summary, plan
# file and bun call log.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-prod-apply-bun.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/preview-and-guard-prod.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo/program" "$tree/runner"
  : > "$tree/calls"
  : > "$tree/output"
  : > "$tree/summary"
  create_stub_prod_apply_bun "$tree/bin"
}

@test "it passes the plan with verdict apply and shows the guard s text" {
  setup_test "$tree"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_PLAN='{"steps":[{"op":"same"}]}' STUB_GUARD='The guard passes the plan: no held step.' \
    PROGRAM="$tree/repo/program" RUNNER_TEMP="$tree/runner" DRIFT=success GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script"

  assert_output 'The guard passes the plan: no held step.'
  assert_stderr '$ tsrs -p sdk/onidel/tsconfig.json && cp sdk/onidel/package.json sdk/onidel/bin/package.json'

  run -0 diff - "$tree/output" <<< 'verdict=apply'
  run -0 diff - "$tree/summary" <<< 'The guard passes the plan: no held step.'
  run -0 diff - "$tree/runner/plan.json" <<< '{"steps":[{"op":"same"}]}'
  run -0 diff - "$tree/calls" << EOF
{"cwd":"$tree/repo/program","argv":["bun","run","sdk:build"]}
{"cwd":"$tree/repo/program","argv":["bun","run","--silent","preview","--","--refresh","--json"]}
{"cwd":"$tree/repo","argv":["bun","run","--silent","ci:check-prod-plan","$tree/runner/plan.json","success"]}
EOF
}

@test "it holds the plan with verdict hold when the guard exits 3" {
  setup_test "$tree"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_PLAN='{"steps":[{"op":"replace"}]}' STUB_GUARD='Held: the drift check failed.' STUB_GUARD_EXIT=3 \
    PROGRAM="$tree/repo/program" RUNNER_TEMP="$tree/runner" DRIFT=failure GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script"

  assert_output 'Held: the drift check failed.'
  assert_stderr '$ tsrs -p sdk/onidel/tsconfig.json && cp sdk/onidel/package.json sdk/onidel/bin/package.json'

  run -0 diff - "$tree/output" <<< 'verdict=hold'
  run -0 diff - "$tree/summary" <<< 'Held: the drift check failed.'
  run -0 diff - "$tree/runner/plan.json" <<< '{"steps":[{"op":"replace"}]}'
  run -0 diff - "$tree/calls" << EOF
{"cwd":"$tree/repo/program","argv":["bun","run","sdk:build"]}
{"cwd":"$tree/repo/program","argv":["bun","run","--silent","preview","--","--refresh","--json"]}
{"cwd":"$tree/repo","argv":["bun","run","--silent","ci:check-prod-plan","$tree/runner/plan.json","failure"]}
EOF
}

@test "it shows the guard s text then fails naming the preview s status when the preview fails" {
  setup_test "$tree"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_PREVIEW_EXIT=255 STUB_GUARD='The plan is not JSON.' STUB_GUARD_EXIT=1 \
    PROGRAM="$tree/repo/program" RUNNER_TEMP="$tree/runner" DRIFT=success GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script"

  assert_output 'The plan is not JSON.'
  assert_stderr - << 'EOF'
$ tsrs -p sdk/onidel/tsconfig.json && cp sdk/onidel/package.json sdk/onidel/bin/package.json
the preview failed (exit 255)
EOF

  run -0 diff /dev/null "$tree/output"
  run -0 diff - "$tree/summary" <<< 'The plan is not JSON.'
  run -0 diff /dev/null "$tree/runner/plan.json"
  run -0 diff - "$tree/calls" << EOF
{"cwd":"$tree/repo/program","argv":["bun","run","sdk:build"]}
{"cwd":"$tree/repo/program","argv":["bun","run","--silent","preview","--","--refresh","--json"]}
{"cwd":"$tree/repo","argv":["bun","run","--silent","ci:check-prod-plan","$tree/runner/plan.json","success"]}
EOF
}

@test "it fails with no verdict when the guard fails with any other status" {
  setup_test "$tree"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_PLAN='{"steps":[]}' STUB_GUARD='usage: check-prod-plan.ts <plan> <drift outcome>' STUB_GUARD_EXIT=2 \
    PROGRAM="$tree/repo/program" RUNNER_TEMP="$tree/runner" DRIFT=success GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script"

  assert_output 'usage: check-prod-plan.ts <plan> <drift outcome>'
  assert_stderr '$ tsrs -p sdk/onidel/tsconfig.json && cp sdk/onidel/package.json sdk/onidel/bin/package.json'

  run -0 diff /dev/null "$tree/output"
  run -0 diff - "$tree/summary" <<< 'usage: check-prod-plan.ts <plan> <drift outcome>'
  run -0 diff - "$tree/calls" << EOF
{"cwd":"$tree/repo/program","argv":["bun","run","sdk:build"]}
{"cwd":"$tree/repo/program","argv":["bun","run","--silent","preview","--","--refresh","--json"]}
{"cwd":"$tree/repo","argv":["bun","run","--silent","ci:check-prod-plan","$tree/runner/plan.json","success"]}
EOF
}

@test "it stops before the preview with the sdk build s status when the build fails" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SDK_BUILD_EXIT=2 \
    PROGRAM="$tree/repo/program" RUNNER_TEMP="$tree/runner" DRIFT=success GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script"

  refute_output
  assert_stderr - << 'EOF'
$ tsrs -p sdk/onidel/tsconfig.json && cp sdk/onidel/package.json sdk/onidel/bin/package.json
error: script "sdk:build" exited with code 2
EOF

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
  refute [ -e "$tree/runner/plan.json" ]
  refute [ -L "$tree/runner/plan.json" ]
  run -0 diff - "$tree/calls" <<< "{\"cwd\":\"$tree/repo/program\",\"argv\":[\"bun\",\"run\",\"sdk:build\"]}"
}

@test "it refuses to run without the drift outcome" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    RUNNER_TEMP="$tree/runner" GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script"

  refute_output
  assert_stderr 'preview-and-guard-prod: set DRIFT'

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
  run -0 diff /dev/null "$tree/calls"
}

@test "it refuses to run without the program checkout" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    RUNNER_TEMP="$tree/runner" DRIFT=success GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script"

  refute_output
  assert_stderr 'preview-and-guard-prod: set PROGRAM'

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
  run -0 diff /dev/null "$tree/calls"
}
