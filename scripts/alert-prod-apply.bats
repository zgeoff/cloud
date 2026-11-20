#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for alert-prod-apply.sh: it resolves the webhook from the env file's ALERT_WEBHOOK_URL
# reference, prints only its ::add-mask:: line, and posts "held for a manual dispatch" for a run
# that ended held, that a check of nixie failed for a run whose check job failed, and "failed" for
# every other run; it fails with curl's status when the
# webhook refuses the post, with op's when the reference does not resolve, and before op runs for
# an env file without the variable, an empty 1Password token, a missing GitHub variable or a bad
# argument. op and curl are stand-ins (create-stub-op-read.sh, create-stub-webhook-curl.sh). Each
# case runs the script under `env -i` and compares its whole stdout, stderr, call log and posted
# body.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-op-read.sh'
  load 'src/test-utils/shell/create-stub-webhook-curl.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/alert-prod-apply.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_op_read "$tree/bin"
  create_stub_webhook_curl "$tree/bin"
}

@test "it posts that the apply failed when the apply job never gave an outcome" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/alert-webhook"
  printf '%s' https://discord.example/api/webhooks/1/secret > "$tree/vault/cloud-deploy/alert-webhook/credential"
  printf '# alerts\nALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    OUTCOME= RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env"

  assert_output '::add-mask::https://discord.example/api/webhooks/1/secret'
  refute_stderr

  run -0 diff - "$tree/calls" << 'EOF'
["op","read","--no-newline","op://cloud-deploy/alert-webhook/credential"]
["curl","-fsS","-H","Content-Type: application/json","--data","@-","https://discord.example/api/webhooks/1/secret"]
EOF
  run -0 diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The prod apply failed: https://github.com/zgeoff/cloud/actions/runs/7"
}
EOF
}

@test "it posts that the apply is held when the run ended held" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/alert-webhook"
  printf '%s' https://discord.example/api/webhooks/1/secret > "$tree/vault/cloud-deploy/alert-webhook/credential"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    OUTCOME=held RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env"

  assert_output '::add-mask::https://discord.example/api/webhooks/1/secret'
  refute_stderr

  run -0 diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The prod apply is held for a manual dispatch: https://github.com/zgeoff/cloud/actions/runs/7"
}
EOF
}

@test "it posts that the apply failed when the apply itself failed" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/alert-webhook"
  printf '%s' https://discord.example/api/webhooks/1/secret > "$tree/vault/cloud-deploy/alert-webhook/credential"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    OUTCOME=apply RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env"

  assert_output '::add-mask::https://discord.example/api/webhooks/1/secret'
  refute_stderr

  run -0 diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The prod apply failed: https://github.com/zgeoff/cloud/actions/runs/7"
}
EOF
}

@test "it posts that a check of nixie failed when the check job failed after the apply" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/alert-webhook"
  printf '%s' https://discord.example/api/webhooks/1/secret > "$tree/vault/cloud-deploy/alert-webhook/credential"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    OUTCOME=apply CHECK_RESULT=failure RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env"

  assert_output '::add-mask::https://discord.example/api/webhooks/1/secret'
  refute_stderr

  run -0 diff - "$tree/webhook-body" << 'EOF'
{
  "content": "The prod apply passed, but a check of nixie after it failed: https://github.com/zgeoff/cloud/actions/runs/7"
}
EOF
}

@test "it fails with curls status when the webhook refuses the post" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/alert-webhook"
  printf '%s' https://discord.example/api/webhooks/1/secret > "$tree/vault/cloud-deploy/alert-webhook/credential"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  run -22 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub STUB_WEBHOOK_STATUS=404 \
    OUTCOME= RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env"

  assert_output '::add-mask::https://discord.example/api/webhooks/1/secret'
  assert_stderr 'curl: (22) The requested URL returned error: 404'
}

@test "it fails with ops status and posts nothing when the reference does not resolve" {
  setup_test "$tree"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    OUTCOME= RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env"

  refute_output
  assert_stderr '[ERROR] 2026/10/07 12:00:00 could not read secret op://cloud-deploy/alert-webhook/credential: could not get item cloud-deploy/alert-webhook: "alert-webhook" isn'"'"'t an item in the "cloud-deploy" vault.'

  run -0 diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud-deploy/alert-webhook/credential"]'
  refute [ -e "$tree/webhook-body" ]
  refute [ -L "$tree/webhook-body" ]
}

@test "it fails before op runs when the env file sets no webhook" {
  setup_test "$tree"
  printf 'OTHER=op://cloud-deploy/other/credential\n' > "$tree/.env"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    OUTCOME= RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env"

  refute_output
  assert_stderr "alert-prod-apply: $tree/.env sets no ALERT_WEBHOOK_URL"

  run -0 diff /dev/null "$tree/calls"
}

@test "it fails before op runs and names the token when the token is empty" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/alert-webhook"
  printf '%s' https://discord.example/api/webhooks/1/secret > "$tree/vault/cloud-deploy/alert-webhook/credential"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN= \
    OUTCOME= RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script" "$tree/.env"

  refute_output
  assert_stderr "alert-prod-apply: OP_SERVICE_ACCOUNT_TOKEN is empty; set the prod environment's secret to the deploy account's token"

  run -0 diff /dev/null "$tree/calls"
}

@test "it fails before op runs without the run url" {
  setup_test "$tree"
  printf 'ALERT_WEBHOOK_URL=op://cloud-deploy/alert-webhook/credential\n' > "$tree/.env"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    OUTCOME= \
    bash "$script" "$tree/.env"

  refute_output
  assert_stderr "$script: line 24: RUN_URL: parameter null or not set"

  run -0 diff /dev/null "$tree/calls"
}

@test "it rejects a missing env file argument with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" OP_SERVICE_ACCOUNT_TOKEN=ops_stub \
    OUTCOME= RUN_URL=https://github.com/zgeoff/cloud/actions/runs/7 \
    bash "$script"

  refute_output
  assert_stderr 'usage: alert-prod-apply.sh <env file>'

  run -0 diff /dev/null "$tree/calls"
}
