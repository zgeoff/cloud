#!/usr/bin/env bash
# Test for create-stub-gh.sh: the gh stand-in logs each call and the telemetry and update
# opt-outs it ran with, answers a release download as the real gh does for a missing
# release, and fails closed on any other call. No gh runs here; the missing-release answer
# is pinned against the real gh in test-start-stub-github-api.sh.
#
#   bash scripts/test-lib/test-create-stub-gh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-gh.sh"

it_answers_a_release_download_with_release_not_found_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh release download v1.0.0 -R zgeoff/atc -p atc -D "$tree/download" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'release not found'
  diff - "$tree/calls" <<< "[\"gh\",\"release\",\"download\",\"v1.0.0\",\"-R\",\"zgeoff/atc\",\"-p\",\"atc\",\"-D\",\"$tree/download\"]"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_records_the_opt_outs_it_ran_with() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TELEMETRY=0 DO_NOT_TRACK=1 GH_NO_UPDATE_NOTIFIER=1 \
    gh release download v1.0.0 > /dev/null 2>&1 || true

  diff - "$tree/gh-env" <<< 'GH_TELEMETRY=0 DO_NOT_TRACK=1 GH_NO_UPDATE_NOTIFIER=1'
}

it_records_unset_for_each_opt_out_it_ran_without() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh release download v1.0.0 > /dev/null 2>&1 || true

  diff - "$tree/gh-env" <<< 'GH_TELEMETRY=unset DO_NOT_TRACK=unset GH_NO_UPDATE_NOTIFIER=unset'
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    gh auth status > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: auth status'
  diff - "$tree/calls" <<< '["gh","auth","status"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, and the HOME and TMPDIR it runs
# with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_gh "$tree/bin"
}

run_cases
