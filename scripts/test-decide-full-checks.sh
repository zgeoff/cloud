#!/usr/bin/env bash
# Test for decide-full-checks.sh: against a real git repository in the case tree, it appends
# full=true to the step outputs for a change to any file that is not Markdown, and full=false for a
# change to Markdown files only, which it also reports on stdout and in the step summary; it
# fails with the decision's own error and status, writing no output, when the decision fails; and
# it requires both GitHub files. Each case runs the script under `env -i` with git's global and
# system config off, and compares its whole stdout, stderr, outputs and summary.
#
#   bash scripts/test-decide-full-checks.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decide-full-checks.sh"

it_writes_full_true_after_the_existing_outputs_for_a_change_to_a_script() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  mkdir "$tree/repo/scripts"
  echo 'echo fixture' > "$tree/repo/scripts/fixture.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a script'
  echo 'earlier=1' > "$tree/outputs"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/outputs" GITHUB_STEP_SUMMARY="$tree/summary" bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/outputs" << 'EOF'
earlier=1
full=true
EOF
  [ ! -e "$tree/summary" ]
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_writes_full_false_and_reports_the_skipped_checks_for_a_markdown_change() {
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

  diff - "$tree/out" <<< 'Only Markdown files changed, so the Nix-image linters and the shell suites did not run.'
  diff /dev/null "$tree/err"
  diff - "$tree/outputs" <<< 'full=false'
  diff - "$tree/summary" << 'EOF'
## Earlier step
Only Markdown files changed, so the Nix-image linters and the shell suites did not run.
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
fatal: Not a valid object name no-such-ref
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
  diff - "$tree/err" <<< 'usage: needs-full-checks.sh <base> <head>'
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
  # boot data: an empty root commit, so HEAD resolves before a case commits anything of its own
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
