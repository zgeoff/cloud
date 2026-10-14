#!/usr/bin/env bash
# Test for create-stub-bot-user-gh.sh: the gh stand-in prints a bot user's id from the tree,
# decoding the brackets in the login, answers a user the tree lacks as gh does for a 404, logs every
# call, and fails closed on any other call.
#
#   bash test-support/shell/test-create-stub-bot-user-gh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-bot-user-gh.sh"

it_prints_the_id_of_a_bot_user_the_tree_holds() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 41898282 > "$tree/users/cloud-release-check[bot]"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh api 'users/cloud-release-check%5Bbot%5D' --jq .id > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 41898282
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","users/cloud-release-check%5Bbot%5D","--jq",".id"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_answers_a_user_the_tree_lacks_as_gh_does_for_a_404() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh api 'users/no-such-app%5Bbot%5D' --jq .id > "$tree/out" 2> "$tree/err" || status=$?

  printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}' > "$tree/want"
  diff "$tree/want" "$tree/out"
  diff - "$tree/err" <<< 'gh: Not Found (HTTP 404)'
  diff - "$tree/calls" <<< '["gh","api","users/no-such-app%5Bbot%5D","--jq",".id"]'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh api 'users/cloud-release-check%5Bbot%5D' --jq .login > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: api users/cloud-release-check%5Bbot%5D --jq .login'
  diff - "$tree/calls" <<< '["gh","api","users/cloud-release-check%5Bbot%5D","--jq",".login"]'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

# setup_test <tree>: the gh stand-in in <tree>/bin, the home and temp folders it runs with, and
# <tree>/users, where a case states the users GitHub knows.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/users"
  create_stub_bot_user_gh "$tree/bin"
}

run_cases
