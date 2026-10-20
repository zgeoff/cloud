#!/usr/bin/env bash
# Test for check-scheduled-drift.sh: it runs a preview-only refresh of prod in infra/ that leaves
# out the Onidel and Kubernetes resources and passes extra arguments on, writes outcome=clean for a
# refresh that exits 0, outcome=drift for Pulumi's exit 7, and outcome=failed for any other
# status, exits with the refresh's status, runs the refresh again after a failed plugin download,
# and refuses to run without GITHUB_OUTPUT. pulumi is a stand-in
# (create-stub-scripted-command.sh), and the retry's pause is create-stub-clock.sh's sleep, first
# on PATH. Each case runs the script under `env -i` and compares its whole stdout, stderr, call log
# and output file.
#
#   bash scripts/test-check-scheduled-drift.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-clock.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-scripted-command.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-scheduled-drift.sh"
infra="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra" && pwd)"

it_writes_outcome_clean_and_exits_0_when_the_refresh_finds_no_change() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'Resources:\n    61 unchanged\n' > "$tree/answers/1.out"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" GITHUB_OUTPUT="$tree/github-output" \
    bash "$script" --suppress-outputs > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
Resources:
    61 unchanged
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
{"cwd":"$infra","argv":["pulumi","refresh","--stack","prod","--preview-only","--expect-no-changes","--non-interactive","--exclude","urn:pulumi:prod::geoff-cloud::**onidel:index:**","--exclude","urn:pulumi:prod::geoff-cloud::**kubernetes:**","--suppress-outputs"]}
EOF
  diff - "$tree/github-output" <<< 'outcome=clean'
  assert_status 0 "$status"
}

it_writes_outcome_drift_and_exits_7_when_the_refresh_finds_a_change() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'Resources:\n    ~ 1 to update\n    60 unchanged\n' > "$tree/answers/1.out"
  printf 'error: no changes were expected for refresh but changes were proposed\n' > "$tree/answers/1.err"
  echo 7 > "$tree/answers/1.status"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" GITHUB_OUTPUT="$tree/github-output" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
Resources:
    ~ 1 to update
    60 unchanged
error: no changes were expected for refresh but changes were proposed
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
{"cwd":"$infra","argv":["pulumi","refresh","--stack","prod","--preview-only","--expect-no-changes","--non-interactive","--exclude","urn:pulumi:prod::geoff-cloud::**onidel:index:**","--exclude","urn:pulumi:prod::geoff-cloud::**kubernetes:**"]}
EOF
  diff - "$tree/github-output" <<< 'outcome=drift'
  [ ! -e "$tree/clock/pauses" ] || {
    echo "it paused: $(cat "$tree/clock/pauses")" >&2
    exit 1
  }
  assert_status 7 "$status"
}

it_writes_outcome_failed_and_exits_with_the_refresh_s_status_on_any_other_error() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'error: get stack secrets manager: passphrase must be set with PULUMI_CONFIG_PASSPHRASE or PULUMI_CONFIG_PASSPHRASE_FILE environment variables\n' > "$tree/answers/1.err"
  echo 1 > "$tree/answers/1.status"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" GITHUB_OUTPUT="$tree/github-output" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'error: get stack secrets manager: passphrase must be set with PULUMI_CONFIG_PASSPHRASE or PULUMI_CONFIG_PASSPHRASE_FILE environment variables'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
{"cwd":"$infra","argv":["pulumi","refresh","--stack","prod","--preview-only","--expect-no-changes","--non-interactive","--exclude","urn:pulumi:prod::geoff-cloud::**onidel:index:**","--exclude","urn:pulumi:prod::geoff-cloud::**kubernetes:**"]}
EOF
  diff - "$tree/github-output" <<< 'outcome=failed'
  assert_status 1 "$status"
}

it_runs_the_refresh_again_after_a_failed_plugin_download_and_writes_the_last_try_s_outcome() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'error: Could not automatically download and install resource plugin pulumi-resource-cloudflare\n' > "$tree/answers/1.err"
  echo 255 > "$tree/answers/1.status"
  printf 'Resources:\n    61 unchanged\n' > "$tree/answers/2.out"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" GITHUB_OUTPUT="$tree/github-output" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
error: Could not automatically download and install resource plugin pulumi-resource-cloudflare
Resources:
    61 unchanged
EOF
  diff - "$tree/err" <<< 'retry-transient-pulumi: try 1 of 3 failed (exit 255) on an error a later try can pass; trying again in 60s'
  diff - "$tree/calls" << EOF
{"cwd":"$infra","argv":["pulumi","refresh","--stack","prod","--preview-only","--expect-no-changes","--non-interactive","--exclude","urn:pulumi:prod::geoff-cloud::**onidel:index:**","--exclude","urn:pulumi:prod::geoff-cloud::**kubernetes:**"]}
{"cwd":"$infra","argv":["pulumi","refresh","--stack","prod","--preview-only","--expect-no-changes","--non-interactive","--exclude","urn:pulumi:prod::geoff-cloud::**onidel:index:**","--exclude","urn:pulumi:prod::geoff-cloud::**kubernetes:**"]}
EOF
  diff - "$tree/clock/pauses" <<< '60'
  diff - "$tree/github-output" <<< 'outcome=clean'
  assert_status 0 "$status"
}

it_refuses_to_run_without_github_output() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'check-scheduled-drift: set GITHUB_OUTPUT'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/clock" "$tree/home" "$tree/tmp" "$tree/answers"
  : > "$tree/calls"
  create_stub_clock "$tree/clock"
  create_stub_scripted_command "$tree/bin" pulumi
}

run_cases
