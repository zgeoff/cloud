#!/usr/bin/env bash
# Test for create-stub-deploy-tag-gh.sh: the gh stand-in answers the deployed/prod move with the
# updated reference, refuses it as GitHub refuses a move that is not a fast forward, logs every
# call, and fails closed on any other call.
#
#   bash scripts/test-lib/test-create-stub-deploy-tag-gh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-deploy-tag-gh.sh"

it_answers_a_move_with_the_updated_reference() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh api --method PATCH repos/zgeoff/cloud/git/refs/tags/deployed/prod -f sha=1111111111111111111111111111111111111111 -F force=false > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '{"ref":"refs/tags/deployed/prod","url":"https://api.github.com/repos/zgeoff/cloud/git/refs/tags/deployed/prod","object":{"sha":"1111111111111111111111111111111111111111","type":"commit","url":"https://api.github.com/repos/zgeoff/cloud/git/commits/1111111111111111111111111111111111111111"}}'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","--method","PATCH","repos/zgeoff/cloud/git/refs/tags/deployed/prod","-f","sha=1111111111111111111111111111111111111111","-F","force=false"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_refuses_a_move_that_is_not_a_fast_forward_with_githubs_422() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_TAG_MOVE=refused \
    gh api --method PATCH repos/zgeoff/cloud/git/refs/tags/deployed/prod -f sha=1111111111111111111111111111111111111111 -F force=false > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '{"message":"Update is not a fast forward","documentation_url":"https://docs.github.com/rest/git/refs#update-a-reference","status":"422"}'
  diff - "$tree/err" <<< 'gh: Update is not a fast forward (HTTP 422)'
  diff - "$tree/calls" <<< '["gh","api","--method","PATCH","repos/zgeoff/cloud/git/refs/tags/deployed/prod","-f","sha=1111111111111111111111111111111111111111","-F","force=false"]'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_closed_with_exit_97_on_a_forced_move() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh api --method PATCH repos/zgeoff/cloud/git/refs/tags/deployed/prod -f sha=1111111111111111111111111111111111111111 -F force=true > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: api --method PATCH repos/zgeoff/cloud/git/refs/tags/deployed/prod -f sha=1111111111111111111111111111111111111111 -F force=true'
  diff - "$tree/calls" <<< '["gh","api","--method","PATCH","repos/zgeoff/cloud/git/refs/tags/deployed/prod","-f","sha=1111111111111111111111111111111111111111","-F","force=true"]'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

it_fails_closed_with_exit_97_on_another_tag() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh api --method PATCH repos/zgeoff/cloud/git/refs/tags/deployed/staging -f sha=1111111111111111111111111111111111111111 -F force=false > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: api --method PATCH repos/zgeoff/cloud/git/refs/tags/deployed/staging -f sha=1111111111111111111111111111111111111111 -F force=false'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_deploy_tag_gh "$tree/bin"
}

run_cases
