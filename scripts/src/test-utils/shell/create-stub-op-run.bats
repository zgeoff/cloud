#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-op-run.sh: the op stand-in runs the command after `run --env-file=<file> --`
# in the caller's directory, with its output and its exit status, when <file> exists, and fails
# closed with exit 97 on a missing env file or any other call. Each case logs to its own file.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-op-run.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
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
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/work/infra"
  : > "$tree/calls"
  create_stub_op_run "$tree/bin" "$tree/calls"
}

@test "it runs the command in the caller s directory with its output and status" {
  setup_test "$tree"
  printf 'API_TOKEN=op://example/api/credential\n' > "$tree/work/.env"

  run -5 --separate-stderr in_dir "$tree/work/infra" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    op run --env-file=../.env -- bash -c 'pwd; echo to stderr >&2; exit 5'

  assert_output "$tree/work/infra"
  assert_stderr 'to stderr'
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/work/infra\",\"argv\":[\"op\",\"run\",\"--env-file=../.env\",\"--\",\"bash\",\"-c\",\"pwd; echo to stderr >&2; exit 5\"]}"
}

@test "it fails closed on an env file that does not exist" {
  setup_test "$tree"

  run -97 --separate-stderr in_dir "$tree/work/infra" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    op run --env-file=../.env -- echo ran

  refute_output
  assert_stderr 'unexpected: run --env-file=../.env -- echo ran'
}

@test "it fails closed on any other call" {
  setup_test "$tree"
  printf 'API_TOKEN=op://example/api/credential\n' > "$tree/work/.env"

  run -97 --separate-stderr in_dir "$tree/work/infra" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    op read op://example/api/credential

  refute_output
  assert_stderr 'unexpected: read op://example/api/credential'
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/work/infra\",\"argv\":[\"op\",\"read\",\"op://example/api/credential\"]}"
}
