#!/usr/bin/env bash
# Test for alert-scheduled-drift.sh: it posts "found drift in prod" for a check that ended with
# drift and "failed" for every other outcome, an empty one included, never prints the webhook,
# fails with curl's status when the webhook refuses the post, and fails before curl runs for an
# empty webhook, an empty run URL or an argument. curl is a stand-in
# (create-stub-webhook-curl.sh). Each case runs the script under `env -i` and compares its whole
# stdout, stderr, call log and posted body.
#
#   bash scripts/test-alert-scheduled-drift.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-webhook-curl.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/alert-scheduled-drift.sh"

it_posts_that_the_check_found_drift_when_the_check_ended_with_drift() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OUTCOME=drift RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/1/secret \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["curl","-fsS","-H","Content-Type: application/json","--data","@-","https://discord.example/api/webhooks/1/secret"]
EOF
  diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The scheduled drift check found drift in prod: https://github.com/zgeoff/cloud/actions/runs/7"
}
EOF
  assert_status 0 "$status"
}

it_posts_that_the_check_failed_when_the_refresh_failed() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OUTCOME=failed RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/1/secret \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The scheduled drift check failed: https://github.com/zgeoff/cloud/actions/runs/7"
}
EOF
  assert_status 0 "$status"
}

it_posts_that_the_check_failed_when_the_check_job_never_gave_an_outcome() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OUTCOME= RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/1/secret \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The scheduled drift check failed: https://github.com/zgeoff/cloud/actions/runs/7"
}
EOF
  assert_status 0 "$status"
}

it_fails_with_curls_status_when_the_webhook_refuses_the_post() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_WEBHOOK_STATUS=404 \
    OUTCOME=drift RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/1/secret \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 404'
  assert_status 22 "$status"
}

it_fails_before_curl_runs_when_the_webhook_is_empty() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OUTCOME=drift RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 ALERT_WEBHOOK_URL= \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'alert-scheduled-drift: ALERT_WEBHOOK_URL is empty'
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_fails_before_curl_runs_without_the_run_url() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OUTCOME=drift ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/1/secret \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'alert-scheduled-drift: RUN_URL is empty'
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_rejects_an_argument_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OUTCOME=drift RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/1/secret \
    bash "$script" .env > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: alert-scheduled-drift.sh'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_webhook_curl "$tree/bin"
}

run_cases
