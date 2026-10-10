#!/usr/bin/env bash
# Test for create-stub-imp.sh: the imp stand-in logs each call, keeps images and imps in its
# state file, builds an image from a folder it copies aside, fails a build on request, refuses to
# remove a missing image, an image in use or a missing imp, and to create an imp on a missing
# image or under a taken name, and fails closed on any other call.
#
#   bash scripts/test-lib/test-create-stub-imp.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-imp.sh"

# Runtime every case needs: the stand-in in <tree>/bin, and the HOME and TMPDIR it runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_imp "$tree/bin"
}

it_lists_no_image_on_an_empty_host() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    imp image ls --json > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '[]'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["imp","image","ls","--json"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_builds_an_image_from_a_folder_it_copies_aside() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/context"
  echo 'FROM scratch' > "$tree/context/Dockerfile"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    imp image build "$tree/context" --name agent-abc1234 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/build-saw/Dockerfile" <<< 'FROM scratch'
  diff - <(jq -c . "$tree/imp-state.json") <<< '{"images":[{"name":"agent-abc1234","digest":"imp-build-stub-agent-abc1234"}],"imps":[]}'
  diff - <(env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" imp image ls --json) <<< '[{"name":"agent-abc1234","ref":"imp/agent-abc1234:latest","digest":"imp-build-stub-agent-abc1234"}]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_a_build_on_request_and_adds_no_image() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/context"
  echo 'FROM scratch' > "$tree/context/Dockerfile"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_IMP_BUILD_ERROR='imp: BUILD_FAILED: the build exited 1' \
    imp image build "$tree/context" --name agent-abc1234 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'imp: BUILD_FAILED: the build exited 1'
  diff - <(jq -c . "$tree/imp-state.json") <<< '{"images":[],"imps":[]}'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_removes_an_image_no_imp_uses() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"images":[{"name":"agent-abc1234","digest":"imp-build-1"},{"name":"agent-def5678","digest":"imp-build-2"}],"imps":[]}' > "$tree/imp-state.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    imp image rm agent-abc1234 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - <(jq -c . "$tree/imp-state.json") <<< '{"images":[{"name":"agent-def5678","digest":"imp-build-2"}],"imps":[]}'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_refuses_to_remove_a_missing_image() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    imp image rm agent-abc1234 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'imp: NOT_FOUND: image agent-abc1234 not found'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_to_remove_an_image_an_imp_uses() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"images":[{"name":"agent-abc1234","digest":"imp-build-1"}],"imps":[{"name":"home-1","image":"agent-abc1234"}]}' > "$tree/imp-state.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    imp image rm agent-abc1234 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'imp: CONFLICT: image agent-abc1234 is in use'
  diff - <(jq -c . "$tree/imp-state.json") <<< '{"images":[{"name":"agent-abc1234","digest":"imp-build-1"}],"imps":[{"name":"home-1","image":"agent-abc1234"}]}'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_creates_an_imp_on_an_image() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"images":[{"name":"agent-abc1234","digest":"imp-build-1"}],"imps":[]}' > "$tree/imp-state.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    imp new agent-check-abc1234 --image agent-abc1234 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'agent-check-abc1234'
  diff /dev/null "$tree/err"
  diff - <(env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" imp ls --json) <<< '[{"name":"agent-check-abc1234","image":"agent-abc1234"}]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_refuses_an_imp_on_a_missing_image() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    imp new agent-check-abc1234 --image agent-abc1234 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'imp: NOT_FOUND: image agent-abc1234 not found'
  diff - <(jq -c . "$tree/imp-state.json") <<< '{"images":[],"imps":[]}'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_an_imp_under_a_taken_name() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"images":[{"name":"agent-abc1234","digest":"imp-build-1"}],"imps":[{"name":"agent-check-abc1234","image":"agent-abc1234"}]}' > "$tree/imp-state.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    imp new agent-check-abc1234 --image agent-abc1234 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'imp: CONFLICT: imp agent-check-abc1234 already exists'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_removes_an_imp() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"images":[{"name":"agent-abc1234","digest":"imp-build-1"}],"imps":[{"name":"agent-check-abc1234","image":"agent-abc1234"}]}' > "$tree/imp-state.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    imp rm agent-check-abc1234 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - <(jq -c . "$tree/imp-state.json") <<< '{"images":[{"name":"agent-abc1234","digest":"imp-build-1"}],"imps":[]}'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_refuses_to_remove_a_missing_imp() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    imp rm agent-check-abc1234 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'imp: NOT_FOUND: imp agent-check-abc1234 not found'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    imp token ls > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: token ls'
  diff - "$tree/calls" <<< '["imp","token","ls"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

run_cases
