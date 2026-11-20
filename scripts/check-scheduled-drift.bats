#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for check-scheduled-drift.sh: it runs a preview-only refresh of prod in infra/ that leaves
# out the Onidel and Kubernetes resources and passes extra arguments on, writes clean for a
# refresh that exits 0, drift for Pulumi's exit 7, and failed for any other
# status, exits with the refresh's status, runs the refresh again after a failed plugin download,
# and refuses to run without OUTCOME_FILE. pulumi is a stand-in
# (create-stub-scripted-command.sh), and the retry's pause is create-stub-clock.sh's sleep, first
# on PATH. Each case runs the script under `env -i` and compares its whole stdout, stderr, call log
# and output file.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-clock.sh'
  load 'src/test-utils/shell/create-stub-scripted-command.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/check-scheduled-drift.sh"
  infra="$(cd "$BATS_TEST_DIRNAME/../infra" && pwd)"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/clock" "$tree/home" "$tree/tmp" "$tree/answers"
  : > "$tree/calls"
  create_stub_clock "$tree/clock"
  create_stub_scripted_command "$tree/bin" pulumi
}

@test "it writes outcome clean and exits 0 when the refresh finds no change" {
  setup_test "$tree"
  printf 'Resources:\n    61 unchanged\n' > "$tree/answers/1.out"

  run -0 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" OUTCOME_FILE="$tree/outcome" \
    bash "$script" --suppress-outputs

  assert_output - << 'EOF'
Resources:
    61 unchanged
EOF
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
{"cwd":"$infra","argv":["pulumi","refresh","--stack","prod","--preview-only","--expect-no-changes","--non-interactive","--exclude","urn:pulumi:prod::geoff-cloud::**onidel:index:**","--exclude","urn:pulumi:prod::geoff-cloud::**kubernetes:**","--suppress-outputs"]}
EOF
  run -0 diff - "$tree/outcome" <<< 'clean'
}

@test "it writes outcome drift and exits 7 when the refresh finds a change" {
  setup_test "$tree"
  printf 'Resources:\n    ~ 1 to update\n    60 unchanged\n' > "$tree/answers/1.out"
  printf 'error: no changes were expected for refresh but changes were proposed\n' > "$tree/answers/1.err"
  echo 7 > "$tree/answers/1.status"

  run -7 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" OUTCOME_FILE="$tree/outcome" \
    bash "$script"

  assert_output - << 'EOF'
Resources:
    ~ 1 to update
    60 unchanged
error: no changes were expected for refresh but changes were proposed
EOF
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
{"cwd":"$infra","argv":["pulumi","refresh","--stack","prod","--preview-only","--expect-no-changes","--non-interactive","--exclude","urn:pulumi:prod::geoff-cloud::**onidel:index:**","--exclude","urn:pulumi:prod::geoff-cloud::**kubernetes:**"]}
EOF
  run -0 diff - "$tree/outcome" <<< 'drift'
  refute [ -e "$tree/clock/pauses" ]
}

@test "it writes outcome failed and exits with the refresh s status on any other error" {
  setup_test "$tree"
  printf 'error: get stack secrets manager: passphrase must be set with PULUMI_CONFIG_PASSPHRASE or PULUMI_CONFIG_PASSPHRASE_FILE environment variables\n' > "$tree/answers/1.err"
  echo 1 > "$tree/answers/1.status"

  run -1 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" OUTCOME_FILE="$tree/outcome" \
    bash "$script"

  assert_output 'error: get stack secrets manager: passphrase must be set with PULUMI_CONFIG_PASSPHRASE or PULUMI_CONFIG_PASSPHRASE_FILE environment variables'
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
{"cwd":"$infra","argv":["pulumi","refresh","--stack","prod","--preview-only","--expect-no-changes","--non-interactive","--exclude","urn:pulumi:prod::geoff-cloud::**onidel:index:**","--exclude","urn:pulumi:prod::geoff-cloud::**kubernetes:**"]}
EOF
  run -0 diff - "$tree/outcome" <<< 'failed'
}

@test "it runs the refresh again after a failed plugin download and writes the last try s outcome" {
  setup_test "$tree"
  printf 'error: Could not automatically download and install resource plugin pulumi-resource-cloudflare\n' > "$tree/answers/1.err"
  echo 255 > "$tree/answers/1.status"
  printf 'Resources:\n    61 unchanged\n' > "$tree/answers/2.out"

  run -0 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" OUTCOME_FILE="$tree/outcome" \
    bash "$script"

  assert_output - << 'EOF'
error: Could not automatically download and install resource plugin pulumi-resource-cloudflare
Resources:
    61 unchanged
EOF
  assert_stderr 'retry-transient-pulumi: try 1 of 3 failed (exit 255) on an error a later try can pass; trying again in 60s'

  run -0 diff - "$tree/calls" << EOF
{"cwd":"$infra","argv":["pulumi","refresh","--stack","prod","--preview-only","--expect-no-changes","--non-interactive","--exclude","urn:pulumi:prod::geoff-cloud::**onidel:index:**","--exclude","urn:pulumi:prod::geoff-cloud::**kubernetes:**"]}
{"cwd":"$infra","argv":["pulumi","refresh","--stack","prod","--preview-only","--expect-no-changes","--non-interactive","--exclude","urn:pulumi:prod::geoff-cloud::**onidel:index:**","--exclude","urn:pulumi:prod::geoff-cloud::**kubernetes:**"]}
EOF
  run -0 diff - "$tree/clock/pauses" <<< '60'
  run -0 diff - "$tree/outcome" <<< 'clean'
}

@test "it refuses to run without an outcome file" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script"

  refute_output
  assert_stderr 'check-scheduled-drift: set OUTCOME_FILE'

  run -0 diff /dev/null "$tree/calls"
}
