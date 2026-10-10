#!/usr/bin/env bash
# Test for create-stub-pin-pr-gh.sh: the gh stand-in logs each call, lists the open pull requests
# a test wrote (or none), turns auto-merge off, answers a create and an edit with the pull
# request's URL, and fails closed on any other call.
#
#   bash scripts/test-lib/test-create-stub-pin-pr-gh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-pin-pr-gh.sh"

# Runtime every case needs: the stand-in in <tree>/bin, and the HOME and TMPDIR it runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_pin_pr_gh "$tree/bin"
}

it_lists_no_open_pull_request_when_the_test_wrote_none() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh pr list --repo zgeoff/cloud --head atc-pin/agent-image --state open --json number,autoMergeRequest > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '[]'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","pr","list","--repo","zgeoff/cloud","--head","atc-pin/agent-image","--state","open","--json","number,autoMergeRequest"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_lists_the_open_pull_requests_the_test_wrote() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"autoMergeRequest":null,"number":12}]' > "$tree/open-prs"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh pr list --repo zgeoff/cloud --head atc-pin/agent-image --state open --json number,autoMergeRequest > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '[{"autoMergeRequest":null,"number":12}]'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","pr","list","--repo","zgeoff/cloud","--head","atc-pin/agent-image","--state","open","--json","number,autoMergeRequest"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_turns_auto_merge_off_silently() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh pr merge 12 --repo zgeoff/cloud --disable-auto > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","pr","merge","12","--repo","zgeoff/cloud","--disable-auto"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_answers_a_create_with_the_new_pull_requests_url() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh pr create --repo zgeoff/cloud --base main --head atc-pin/agent-image --title t --body b > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/200'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","pr","create","--repo","zgeoff/cloud","--base","main","--head","atc-pin/agent-image","--title","t","--body","b"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_answers_an_edit_with_the_edited_pull_requests_url() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh pr edit 12 --repo zgeoff/cloud --title t --body b > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/12'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","pr","edit","12","--repo","zgeoff/cloud","--title","t","--body","b"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh pr merge 12 --squash > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: pr merge 12 --squash'
  diff - "$tree/calls" <<< '["gh","pr","merge","12","--squash"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

run_cases
