#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for alert-scheduled-drift.sh: it posts "found drift in prod" for a check that ended with
# drift and "failed" for every other outcome, an empty one included, never prints the webhook,
# fails with curl's status when the webhook refuses the post, and fails before curl runs for an
# empty webhook, an empty run reference or an argument. curl is a stand-in
# (create-stub-webhook-curl.sh). Each case runs the script under `env -i` and compares its whole
# stdout, stderr, call log and posted body.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-webhook-curl.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/alert-scheduled-drift.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_webhook_curl "$tree/bin"
}

@test "it posts that the check found drift when the check ended with drift" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OUTCOME=drift RUN_REF='journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=5f3a9c0e7b2d4e61a8c9f0b1d2e3a4b5' \
    ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/1/secret \
    bash "$script"

  refute_output
  refute_stderr

  run -0 diff - "$tree/calls" << 'EOF'
["curl","-fsS","-H","Content-Type: application/json","--data","@-","https://discord.example/api/webhooks/1/secret"]
EOF
  run -0 diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The scheduled drift check found drift in prod: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=5f3a9c0e7b2d4e61a8c9f0b1d2e3a4b5"
}
EOF
}

@test "it posts that the check failed when the refresh failed" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OUTCOME=failed RUN_REF='journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=5f3a9c0e7b2d4e61a8c9f0b1d2e3a4b5' \
    ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/1/secret \
    bash "$script"

  refute_output
  refute_stderr

  run -0 diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The scheduled drift check failed: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=5f3a9c0e7b2d4e61a8c9f0b1d2e3a4b5"
}
EOF
}

@test "it posts that the check failed when the run never reached the check" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OUTCOME= RUN_REF='journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=5f3a9c0e7b2d4e61a8c9f0b1d2e3a4b5' \
    ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/1/secret \
    bash "$script"

  refute_output
  refute_stderr

  run -0 diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The scheduled drift check failed: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=5f3a9c0e7b2d4e61a8c9f0b1d2e3a4b5"
}
EOF
}

@test "it fails with curls status when the webhook refuses the post" {
  setup_test "$tree"

  run -22 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_WEBHOOK_STATUS=404 \
    OUTCOME=drift RUN_REF='journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=5f3a9c0e7b2d4e61a8c9f0b1d2e3a4b5' \
    ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/1/secret \
    bash "$script"

  refute_output
  assert_stderr 'curl: (22) The requested URL returned error: 404'
}

@test "it fails before curl runs when the webhook is empty" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OUTCOME=drift RUN_REF='journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=5f3a9c0e7b2d4e61a8c9f0b1d2e3a4b5' ALERT_WEBHOOK_URL= \
    bash "$script"

  refute_output
  assert_stderr 'alert-scheduled-drift: ALERT_WEBHOOK_URL is empty'

  run -0 diff /dev/null "$tree/calls"
}

@test "it fails before curl runs without the run reference" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OUTCOME=drift ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/1/secret \
    bash "$script"

  refute_output
  assert_stderr 'alert-scheduled-drift: RUN_REF is empty'

  run -0 diff /dev/null "$tree/calls"
}

@test "it rejects an argument with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OUTCOME=drift RUN_REF='journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=5f3a9c0e7b2d4e61a8c9f0b1d2e3a4b5' \
    ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/1/secret \
    bash "$script" .env

  refute_output
  assert_stderr 'usage: alert-scheduled-drift.sh'

  run -0 diff /dev/null "$tree/calls"
}
