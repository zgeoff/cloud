#!/usr/bin/env bash
# Test for create-stub-op-run.sh: the op stand-in runs the command after `run --env-file=<file> --`
# in the caller's directory, with its output and its exit status, when <file> exists, and fails
# closed with exit 97 on a missing env file or any other call. Each case logs to its own file.
#
#   bash test-support/shell/test-create-stub-op-run.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-op-run.sh"

it_runs_the_command_in_the_caller_s_directory_with_its_output_and_status() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'API_TOKEN=op://example/api/credential\n' > "$tree/work/.env"

  (cd "$tree/work/infra" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    op run --env-file=../.env -- bash -c 'pwd; echo to stderr >&2; exit 5') > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "$tree/work/infra"
  diff - "$tree/err" <<< 'to stderr'
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/work/infra\",\"argv\":[\"op\",\"run\",\"--env-file=../.env\",\"--\",\"bash\",\"-c\",\"pwd; echo to stderr >&2; exit 5\"]}"
  assert_status 5 "$status"
}

it_fails_closed_on_an_env_file_that_does_not_exist() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/work/infra" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    op run --env-file=../.env -- echo ran) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: run --env-file=../.env -- echo ran'
  assert_status 97 "$status"
}

it_fails_closed_on_any_other_call() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'API_TOKEN=op://example/api/credential\n' > "$tree/work/.env"

  (cd "$tree/work/infra" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    op read op://example/api/credential) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: read op://example/api/credential'
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/work/infra\",\"argv\":[\"op\",\"read\",\"op://example/api/credential\"]}"
  assert_status 97 "$status"
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/work/infra"
  : > "$tree/calls"
  create_stub_op_run "$tree/bin" "$tree/calls"
}

run_cases
