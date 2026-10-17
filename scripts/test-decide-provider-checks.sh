#!/usr/bin/env bash
# Test for decide-provider-checks.sh: against a real git repository in the case tree, it appends
# provider=true to the step outputs for a change to an input of the provider's checks, and
# provider=false for any other change, which it also reports on stdout and in the step summary; it
# fails with the decision's own error and status, writing no output, when the decision fails; and
# it requires both GitHub files. Each case runs the script under `env -i` with git's global and
# system config off, and compares its whole stdout, stderr, outputs and summary.
#
#   bash scripts/test-decide-provider-checks.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decide-provider-checks.sh"

it_writes_provider_true_after_the_existing_outputs_for_a_change_under_provider() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  mkdir "$tree/repo/provider"
  echo 'module fixture' > "$tree/repo/provider/go.mod"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the module'
  echo 'earlier=1' > "$tree/outputs"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/outputs" GITHUB_STEP_SUMMARY="$tree/summary" bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/outputs" << 'EOF'
earlier=1
provider=true
EOF
  [ ! -e "$tree/summary" ]
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_writes_provider_false_and_reports_the_skipped_checks_for_any_other_change() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo '# notes' > "$tree/repo/README.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the readme'
  echo '## Earlier step' > "$tree/summary"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/outputs" GITHUB_STEP_SUMMARY="$tree/summary" bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'No input of the provider checks changed, so the Go checks did not run.'
  diff /dev/null "$tree/err"
  diff - "$tree/outputs" <<< 'provider=false'
  diff - "$tree/summary" << 'EOF'
## Earlier step
No input of the provider checks changed, so the Go checks did not run.
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_with_gits_error_and_writes_no_output_for_a_base_git_cannot_resolve() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/outputs" GITHUB_STEP_SUMMARY="$tree/summary" bash "$script" no-such-ref HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
fatal: ambiguous argument 'no-such-ref...HEAD': unknown revision or path not in the working tree.
Use '--' to separate paths from revisions, like this:
'git <command> [<revision>...] -- [<file>...]'
ERR
  [ ! -e "$tree/outputs" ]
  [ ! -e "$tree/summary" ]
  [ "$status" = 128 ] || {
    echo "exit $status, want 128" >&2
    exit 1
  }
}

it_fails_with_the_decisions_usage_for_an_empty_base() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/outputs" GITHUB_STEP_SUMMARY="$tree/summary" bash "$script" '' HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: needs-provider-check.sh <base> <head>'
  [ ! -e "$tree/outputs" ]
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_requires_the_step_outputs_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_STEP_SUMMARY="$tree/summary" bash "$script" HEAD HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$script: line 13: GITHUB_OUTPUT: set GITHUB_OUTPUT to the file that takes the step outputs"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_requires_the_step_summary_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/outputs" bash "$script" HEAD HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$script: line 14: GITHUB_STEP_SUMMARY: set GITHUB_STEP_SUMMARY to the file that takes the step summary"
  [ ! -e "$tree/outputs" ]
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp" "$tree/repo"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" init -q -b main
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" config user.name fixture
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" config user.email fixture@example.invalid
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # the case's trap removes it
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves before a case commits anything of its own
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
