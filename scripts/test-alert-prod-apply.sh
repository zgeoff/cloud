#!/usr/bin/env bash
# Test for alert-prod-apply.sh: it resolves the webhook from the env file's ALERT_WEBHOOK_URL
# reference, prints only its ::add-mask:: line, and posts "held for a manual dispatch" for a held
# run no person started and "failed" for every other run; it fails with curl's status when the
# webhook refuses the post, with op's when the reference does not resolve, and before op runs for
# an env file without the variable, an empty 1Password token, a missing GitHub variable or a bad
# argument. op and curl are stand-ins (create-stub-op-read.sh, create-stub-webhook-curl.sh). Each
# case runs the script under `env -i` and compares its whole stdout, stderr, call log and posted
# body.
#
#   bash scripts/test-alert-prod-apply.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-op-read.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-webhook-curl.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/alert-prod-apply.sh"

it_posts_that_the_apply_failed_when_the_apply_job_never_gave_a_verdict() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/alert-webhook"
  printf '%s' https://discord.example/api/webhooks/1/secret > "$tree/vault/cloud-deploy/alert-webhook/credential"
  printf '# alerts\nALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    VERDICT= EVENT=workflow_run RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '::add-mask::https://discord.example/api/webhooks/1/secret'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["op","read","--no-newline","op://cloud-deploy/alert-webhook/credential"]
["curl","-fsS","-H","Content-Type: application/json","--data","@-","https://discord.example/api/webhooks/1/secret"]
EOF
  diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The prod apply failed: https://github.com/zgeoff/cloud/actions/runs/7"
}
EOF
  assert_status 0 "$status"
}

it_posts_that_the_apply_is_held_when_the_guard_held_a_run_no_person_started() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/alert-webhook"
  printf '%s' https://discord.example/api/webhooks/1/secret > "$tree/vault/cloud-deploy/alert-webhook/credential"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    VERDICT=hold EVENT=workflow_run RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '::add-mask::https://discord.example/api/webhooks/1/secret'
  diff /dev/null "$tree/err"
  diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The prod apply is held for a manual dispatch: https://github.com/zgeoff/cloud/actions/runs/7"
}
EOF
  assert_status 0 "$status"
}

it_posts_that_the_apply_failed_when_a_dispatched_run_holds() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/alert-webhook"
  printf '%s' https://discord.example/api/webhooks/1/secret > "$tree/vault/cloud-deploy/alert-webhook/credential"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    VERDICT=hold EVENT=workflow_dispatch RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '::add-mask::https://discord.example/api/webhooks/1/secret'
  diff /dev/null "$tree/err"
  diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The prod apply failed: https://github.com/zgeoff/cloud/actions/runs/7"
}
EOF
  assert_status 0 "$status"
}

it_posts_that_the_apply_failed_when_the_guard_passed_the_plan() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/alert-webhook"
  printf '%s' https://discord.example/api/webhooks/1/secret > "$tree/vault/cloud-deploy/alert-webhook/credential"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    VERDICT=apply EVENT=workflow_run RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '::add-mask::https://discord.example/api/webhooks/1/secret'
  diff /dev/null "$tree/err"
  diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The prod apply failed: https://github.com/zgeoff/cloud/actions/runs/7"
}
EOF
  assert_status 0 "$status"
}

it_fails_with_curls_status_when_the_webhook_refuses_the_post() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/alert-webhook"
  printf '%s' https://discord.example/api/webhooks/1/secret > "$tree/vault/cloud-deploy/alert-webhook/credential"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub STUB_WEBHOOK_STATUS=404 \
    VERDICT= EVENT=workflow_run RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '::add-mask::https://discord.example/api/webhooks/1/secret'
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 404'
  assert_status 22 "$status"
}

it_fails_with_ops_status_and_posts_nothing_when_the_reference_does_not_resolve() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    VERDICT= EVENT=workflow_run RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '[ERROR] 2026/10/07 12:00:00 could not read secret op://cloud-deploy/alert-webhook/credential: could not get item cloud-deploy/alert-webhook: "alert-webhook" isn'"'"'t an item in the "cloud-deploy" vault.'
  diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud-deploy/alert-webhook/credential"]'
  [ ! -e "$tree/webhook-body" ] || {
    echo "it posted: $(cat "$tree/webhook-body")" >&2
    exit 1
  }
  assert_status 1 "$status"
}

it_fails_before_op_runs_when_the_env_file_sets_no_webhook() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'OTHER=op://cloud-deploy/other/credential\n' > "$tree/.env"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    VERDICT= EVENT=workflow_run RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "alert-prod-apply: $tree/.env sets no ALERT_WEBHOOK_URL"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_fails_before_op_runs_and_names_the_token_when_the_token_is_empty() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/alert-webhook"
  printf '%s' https://discord.example/api/webhooks/1/secret > "$tree/vault/cloud-deploy/alert-webhook/credential"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN= \
    VERDICT= EVENT=workflow_run RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "alert-prod-apply: OP_SERVICE_ACCOUNT_TOKEN is empty; set the prod environment's secret to the deploy account's token"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_fails_before_op_runs_without_the_run_url() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    VERDICT= EVENT=workflow_run \
    bash "$script" "$tree/.env" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$script: line 23: RUN_URL: parameter null or not set"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_rejects_a_missing_env_file_argument_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    VERDICT= EVENT=workflow_run RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: alert-prod-apply.sh <env file>'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_op_read "$tree/bin"
  create_stub_webhook_curl "$tree/bin"
}

run_cases
