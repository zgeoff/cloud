#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-prod-apply-bun.sh: the bun stand-in answers the install, the SDK build, the
# preview and the guard that the prod apply job's scripts run, with the output and exit status
# each case sets, echoes the SDK build's script line as bun does (the line the root package.json
# holds), logs every call with its working directory, and fails closed on any other call.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-prod-apply-bun.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  root="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# in_dir <dir> <command…>: runs the command from <dir>
in_dir() {
  cd "$1" && shift && "$@"
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_prod_apply_bun "$tree/bin"
}

@test "it answers an install with exit 0 and logs the directory it ran in" {
  setup_test "$tree"
  mkdir "$tree/work"

  run -0 --separate-stderr in_dir "$tree/work" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bun install --frozen-lockfile

  refute_output
  refute_stderr
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/work\",\"argv\":[\"bun\",\"install\",\"--frozen-lockfile\"]}"
}

@test "it fails an install with the exit the case sets" {
  setup_test "$tree"

  run -1 --separate-stderr in_dir "$tree" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_INSTALL_EXIT=1 bun install --frozen-lockfile

  refute_output
  refute_stderr
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"install\",\"--frozen-lockfile\"]}"
}

@test "it echoes the sdk build script line that the root package json holds" {
  setup_test "$tree"
  jq -r '"$ " + .scripts["sdk:build"]' "$root/package.json" > "$tree/want"

  run -0 --separate-stderr in_dir "$tree" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bun run sdk:build

  refute_output
  assert_stderr "$(cat "$tree/want")"
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"run\",\"sdk:build\"]}"
}

@test "it fails the sdk build with bun s error line and the exit the case sets" {
  setup_test "$tree"

  run -2 --separate-stderr in_dir "$tree" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SDK_BUILD_EXIT=2 bun run sdk:build

  refute_output
  assert_stderr - << 'EOF'
$ tsrs -p sdk/onidel/tsconfig.json && cp sdk/onidel/package.json sdk/onidel/bin/package.json
error: script "sdk:build" exited with code 2
EOF
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"run\",\"sdk:build\"]}"
}

@test "it prints the plan for the preview and exits with the status the case sets" {
  setup_test "$tree"

  run -255 --separate-stderr in_dir "$tree" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_PLAN='{"steps":[]}' STUB_PREVIEW_EXIT=255 bun run --silent preview -- --refresh --json

  assert_output '{"steps":[]}'
  refute_stderr
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"run\",\"--silent\",\"preview\",\"--\",\"--refresh\",\"--json\"]}"
}

@test "it prints the guard text and exits with the status the case sets" {
  setup_test "$tree"

  run -3 --separate-stderr in_dir "$tree" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_GUARD='held: replace urn:a' STUB_GUARD_EXIT=3 bun run --silent ci:check-prod-plan /tmp/plan.json failure

  assert_output 'held: replace urn:a'
  refute_stderr
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"run\",\"--silent\",\"ci:check-prod-plan\",\"/tmp/plan.json\",\"failure\"]}"
}

@test "it fails closed with exit 97 on a guard call without its two arguments" {
  setup_test "$tree"

  run -97 --separate-stderr in_dir "$tree" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bun run --silent ci:check-prod-plan /tmp/plan.json

  refute_output
  assert_stderr 'unexpected: run --silent ci:check-prod-plan /tmp/plan.json'
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"run\",\"--silent\",\"ci:check-prod-plan\",\"/tmp/plan.json\"]}"
}

@test "it fails closed with exit 97 on any other call" {
  setup_test "$tree"

  run -97 --separate-stderr in_dir "$tree" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bun run preview -- --refresh --json

  refute_output
  assert_stderr 'unexpected: run preview -- --refresh --json'
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree\",\"argv\":[\"bun\",\"run\",\"preview\",\"--\",\"--refresh\",\"--json\"]}"
}
