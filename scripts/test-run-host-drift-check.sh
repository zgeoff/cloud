#!/usr/bin/env bash
# Test for run-host-drift-check.sh: it runs the real check-scheduled-drift.sh with every credential
# but the webhook in its environment, under timeout, and posts nothing when the check finds no
# drift; it posts drift, a failed refresh, a provider plugin that cannot start and a check that ran
# out of time through the real alert-scheduled-drift.sh, says which alert it posted, keeps the
# check's status when the alert fails, and posts the failed alert for a step that fails with no
# alert of its own; it fails before the check and posts the failed alert, never the drift alert,
# when a Deploy prod run held the prod lock past the wait, when taking the lock failed and when the
# run never took it; and it fails before the check on a missing credentials file, a missing
# credential, a line with an unknown name, a missing input or an argument.
#
# pulumi is create-stub-scripted-command.sh, which logs the credentials it receives; timeout is
# create-stub-timeout.sh; and Discord is start-stub-discord-webhook.sh on loopback, which the real
# curl posts to. The lock's status file is the case's own, as hold-host-prod-lock.sh writes it, and
# test-hold-prod-lock.sh tests the wait for the lock. Each case runs the script under `env -i` and
# compares its whole stdout, stderr, call logs and posted bodies.
#
#   bash scripts/test-run-host-drift-check.sh
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # each create_case_tree cleanup expands when its case exits
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-missing.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-scripted-command.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-timeout.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/start-stub-discord-webhook.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-host-drift-check.sh"
check="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-scheduled-drift.sh"
infra="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra" && pwd)"
logged_env='PULUMI_BACKEND_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION PULUMI_CONFIG_PASSPHRASE CLOUDFLARE_API_TOKEN TAILSCALE_OAUTH_CLIENT_ID TAILSCALE_OAUTH_CLIENT_SECRET TAILSCALE_TAILNET ALERT_WEBHOOK_URL'

it_runs_the_check_with_every_credential_but_the_webhook_and_posts_nothing_when_it_finds_no_drift() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  cat > "$tree/credentials/drift-check" << EOF
PULUMI_BACKEND_URL=s3://example-state?endpoint=state.example.test
AWS_ACCESS_KEY_ID=example-key-id
AWS_SECRET_ACCESS_KEY=example-secret=with-equals
PULUMI_CONFIG_PASSPHRASE=example passphrase
CLOUDFLARE_API_TOKEN=example-cloudflare-token
TAILSCALE_OAUTH_CLIENT_ID=example-client-id
TAILSCALE_OAUTH_CLIENT_SECRET=example-client-secret
TAILSCALE_TAILNET=example.test
ALERT_WEBHOOK_URL=http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/1/example-token
EOF
  echo 0 > "$tree/lock-status"
  printf 'Resources:\n    61 unchanged\n' > "$tree/answers/1.out"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" STUB_LOG_ENV="$logged_env" \
    STUB_TIMEOUT_LOG="$tree/timeout-calls" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
Resources:
    61 unchanged
run-host-drift-check: no drift
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
{"cwd":"$infra","argv":["pulumi","refresh","--stack","prod","--preview-only","--expect-no-changes","--non-interactive","--exclude","urn:pulumi:prod::geoff-cloud::**onidel:index:**","--exclude","urn:pulumi:prod::geoff-cloud::**kubernetes:**","--suppress-outputs"],"env":{"PULUMI_BACKEND_URL":"s3://example-state?endpoint=state.example.test","AWS_ACCESS_KEY_ID":"example-key-id","AWS_SECRET_ACCESS_KEY":"example-secret=with-equals","AWS_REGION":"auto","PULUMI_CONFIG_PASSPHRASE":"example passphrase","CLOUDFLARE_API_TOKEN":"example-cloudflare-token","TAILSCALE_OAUTH_CLIENT_ID":"example-client-id","TAILSCALE_OAUTH_CLIENT_SECRET":"example-client-secret","TAILSCALE_TAILNET":"example.test"}}
EOF
  diff - "$tree/timeout-calls" << EOF
["timeout","2700","bash","$check","--suppress-outputs"]
EOF
  assert_missing "$tree/discord/requests" "an alert was posted"
  assert_status 0 "$status"
}

it_posts_that_the_check_found_drift_and_exits_7_when_the_refresh_finds_a_change() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  cat > "$tree/credentials/drift-check" << EOF
PULUMI_BACKEND_URL=s3://example-state?endpoint=state.example.test
AWS_ACCESS_KEY_ID=example-key-id
AWS_SECRET_ACCESS_KEY=example-secret
PULUMI_CONFIG_PASSPHRASE=example-passphrase
CLOUDFLARE_API_TOKEN=example-cloudflare-token
TAILSCALE_OAUTH_CLIENT_ID=example-client-id
TAILSCALE_OAUTH_CLIENT_SECRET=example-client-secret
TAILSCALE_TAILNET=example.test
ALERT_WEBHOOK_URL=http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/1/example-token
EOF
  echo 0 > "$tree/lock-status"
  printf 'Resources:\n    ~ 1 to update\n    60 unchanged\n' > "$tree/answers/1.out"
  printf 'error: no changes were expected for refresh but changes were proposed\n' > "$tree/answers/1.err"
  echo 7 > "$tree/answers/1.status"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
Resources:
    ~ 1 to update
    60 unchanged
error: no changes were expected for refresh but changes were proposed
EOF
  diff - "$tree/err" <<< 'run-host-drift-check: posted the drift alert'
  diff - "$tree/discord/requests" <<< 'POST /api/webhooks/1/example-token'
  printf '%s' '{  "content": "The scheduled drift check found drift in prod: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    diff - "$tree/discord/bodies/1.json"
  assert_status 7 "$status"
}

it_posts_that_the_check_failed_and_exits_with_the_refresh_s_status_when_the_refresh_fails() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  cat > "$tree/credentials/drift-check" << EOF
PULUMI_BACKEND_URL=s3://example-state?endpoint=state.example.test
AWS_ACCESS_KEY_ID=example-key-id
AWS_SECRET_ACCESS_KEY=example-secret
PULUMI_CONFIG_PASSPHRASE=example-passphrase
CLOUDFLARE_API_TOKEN=example-cloudflare-token
TAILSCALE_OAUTH_CLIENT_ID=example-client-id
TAILSCALE_OAUTH_CLIENT_SECRET=example-client-secret
TAILSCALE_TAILNET=example.test
ALERT_WEBHOOK_URL=http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/1/example-token
EOF
  echo 0 > "$tree/lock-status"
  printf 'error: failed to load checkpoint: blob (key ".pulumi/stacks/geoff-cloud/prod.json") (code=Unknown): AccessDenied\n' > "$tree/answers/1.err"
  echo 255 > "$tree/answers/1.status"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'error: failed to load checkpoint: blob (key ".pulumi/stacks/geoff-cloud/prod.json") (code=Unknown): AccessDenied'
  diff - "$tree/err" <<< 'run-host-drift-check: posted the failed alert'
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    diff - "$tree/discord/bodies/1.json"
  assert_status 255 "$status"
}

it_posts_that_the_check_failed_when_a_provider_plugin_cannot_start() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  cat > "$tree/credentials/drift-check" << EOF
PULUMI_BACKEND_URL=s3://example-state?endpoint=state.example.test
AWS_ACCESS_KEY_ID=example-key-id
AWS_SECRET_ACCESS_KEY=example-secret
PULUMI_CONFIG_PASSPHRASE=example-passphrase
CLOUDFLARE_API_TOKEN=example-cloudflare-token
TAILSCALE_OAUTH_CLIENT_ID=example-client-id
TAILSCALE_OAUTH_CLIENT_SECRET=example-client-secret
TAILSCALE_TAILNET=example.test
ALERT_WEBHOOK_URL=http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/1/example-token
EOF
  echo 0 > "$tree/lock-status"
  printf 'error: could not load provider for resource urn:pulumi:prod::geoff-cloud::example:index:Thing::example: failed to load plugin /var/lib/example/plugins/resource-example-v1.2.3/pulumi-resource-example: fork/exec /var/lib/example/plugins/resource-example-v1.2.3/pulumi-resource-example: permission denied\n' > "$tree/answers/1.err"
  echo 255 > "$tree/answers/1.status"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'error: could not load provider for resource urn:pulumi:prod::geoff-cloud::example:index:Thing::example: failed to load plugin /var/lib/example/plugins/resource-example-v1.2.3/pulumi-resource-example: fork/exec /var/lib/example/plugins/resource-example-v1.2.3/pulumi-resource-example: permission denied'
  diff - "$tree/err" <<< 'run-host-drift-check: posted the failed alert'
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    diff - "$tree/discord/bodies/1.json"
  assert_status 255 "$status"
}

it_posts_that_the_run_failed_when_a_step_without_its_own_alert_fails() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  cat > "$tree/credentials/drift-check" << EOF
PULUMI_BACKEND_URL=s3://example-state?endpoint=state.example.test
AWS_ACCESS_KEY_ID=example-key-id
AWS_SECRET_ACCESS_KEY=example-secret
PULUMI_CONFIG_PASSPHRASE=example-passphrase
CLOUDFLARE_API_TOKEN=example-cloudflare-token
TAILSCALE_OAUTH_CLIENT_ID=example-client-id
TAILSCALE_OAUTH_CLIENT_SECRET=example-client-secret
TAILSCALE_TAILNET=example.test
ALERT_WEBHOOK_URL=http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/1/example-token
EOF
  echo 0 > "$tree/lock-status"

  # a TMPDIR that does not exist, so the outcome file's mktemp fails
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/missing" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << EOF
mktemp: failed to create file via template '$tree/missing/tmp.XXXXXXXXXX': No such file or directory
run-host-drift-check: the run failed (exit 1)
run-host-drift-check: posted the failed alert
EOF
  diff /dev/null "$tree/calls"
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    diff - "$tree/discord/bodies/1.json"
  assert_status 1 "$status"
}

it_posts_that_the_check_failed_and_exits_124_when_the_check_runs_out_of_time() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  cat > "$tree/credentials/drift-check" << EOF
PULUMI_BACKEND_URL=s3://example-state?endpoint=state.example.test
AWS_ACCESS_KEY_ID=example-key-id
AWS_SECRET_ACCESS_KEY=example-secret
PULUMI_CONFIG_PASSPHRASE=example-passphrase
CLOUDFLARE_API_TOKEN=example-cloudflare-token
TAILSCALE_OAUTH_CLIENT_ID=example-client-id
TAILSCALE_OAUTH_CLIENT_SECRET=example-client-secret
TAILSCALE_TAILNET=example.test
ALERT_WEBHOOK_URL=http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/1/example-token
EOF
  echo 0 > "$tree/lock-status"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" STUB_TIMEOUT_LOG="$tree/timeout-calls" \
    STUB_TIMEOUT_EXPIRE=124 CREDENTIALS_DIRECTORY="$tree/credentials" CHECK_TIMEOUT=60 \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'run-host-drift-check: posted the failed alert'
  diff /dev/null "$tree/calls"
  diff - "$tree/timeout-calls" << EOF
["timeout","60","bash","$check","--suppress-outputs"]
EOF
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    diff - "$tree/discord/bodies/1.json"
  assert_status 124 "$status"
}

it_keeps_the_check_s_status_and_says_so_when_the_alert_fails() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  cat > "$tree/credentials/drift-check" << EOF
PULUMI_BACKEND_URL=s3://example-state?endpoint=state.example.test
AWS_ACCESS_KEY_ID=example-key-id
AWS_SECRET_ACCESS_KEY=example-secret
PULUMI_CONFIG_PASSPHRASE=example-passphrase
CLOUDFLARE_API_TOKEN=example-cloudflare-token
TAILSCALE_OAUTH_CLIENT_ID=example-client-id
TAILSCALE_OAUTH_CLIENT_SECRET=example-client-secret
TAILSCALE_TAILNET=example.test
ALERT_WEBHOOK_URL=http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/1/example-token
EOF
  echo 404 > "$tree/discord/status"
  echo 0 > "$tree/lock-status"
  printf 'Resources:\n    ~ 1 to update\n' > "$tree/answers/1.out"
  echo 7 > "$tree/answers/1.status"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
Resources:
    ~ 1 to update
EOF
  diff - "$tree/err" << 'EOF'
curl: (22) The requested URL returned error: 404
run-host-drift-check: the alert failed (exit 22)
EOF
  diff - "$tree/discord/requests" <<< 'POST /api/webhooks/1/example-token'
  assert_status 7 "$status"
}

it_fails_before_the_check_and_posts_the_failed_alert_not_drift_when_a_deploy_prod_run_held_the_lock_past_the_wait() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  cat > "$tree/credentials/drift-check" << EOF
PULUMI_BACKEND_URL=s3://example-state?endpoint=state.example.test
AWS_ACCESS_KEY_ID=example-key-id
AWS_SECRET_ACCESS_KEY=example-secret
PULUMI_CONFIG_PASSPHRASE=example-passphrase
CLOUDFLARE_API_TOKEN=example-cloudflare-token
TAILSCALE_OAUTH_CLIENT_ID=example-client-id
TAILSCALE_OAUTH_CLIENT_SECRET=example-client-secret
TAILSCALE_TAILNET=example.test
ALERT_WEBHOOK_URL=http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/1/example-token
EOF
  echo 75 > "$tree/lock-status"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" STUB_TIMEOUT_LOG="$tree/timeout-calls" \
    CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
run-host-drift-check: a Deploy prod run held the prod lock past the wait
run-host-drift-check: posted the failed alert
EOF
  diff /dev/null "$tree/calls"
  assert_missing "$tree/timeout-calls" "the check ran"
  diff - "$tree/discord/requests" <<< 'POST /api/webhooks/1/example-token'
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    diff - "$tree/discord/bodies/1.json"
  assert_status 1 "$status"
}

it_fails_before_the_check_and_posts_when_taking_the_lock_failed() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  cat > "$tree/credentials/drift-check" << EOF
PULUMI_BACKEND_URL=s3://example-state?endpoint=state.example.test
AWS_ACCESS_KEY_ID=example-key-id
AWS_SECRET_ACCESS_KEY=example-secret
PULUMI_CONFIG_PASSPHRASE=example-passphrase
CLOUDFLARE_API_TOKEN=example-cloudflare-token
TAILSCALE_OAUTH_CLIENT_ID=example-client-id
TAILSCALE_OAUTH_CLIENT_SECRET=example-client-secret
TAILSCALE_TAILNET=example.test
ALERT_WEBHOOK_URL=http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/1/example-token
EOF
  echo 1 > "$tree/lock-status"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
run-host-drift-check: taking the prod lock failed (exit 1)
run-host-drift-check: posted the failed alert
EOF
  diff /dev/null "$tree/calls"
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    diff - "$tree/discord/bodies/1.json"
  assert_status 1 "$status"
}

it_fails_before_the_check_and_posts_when_the_run_never_took_the_lock() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  cat > "$tree/credentials/drift-check" << EOF
PULUMI_BACKEND_URL=s3://example-state?endpoint=state.example.test
AWS_ACCESS_KEY_ID=example-key-id
AWS_SECRET_ACCESS_KEY=example-secret
PULUMI_CONFIG_PASSPHRASE=example-passphrase
CLOUDFLARE_API_TOKEN=example-cloudflare-token
TAILSCALE_OAUTH_CLIENT_ID=example-client-id
TAILSCALE_OAUTH_CLIENT_SECRET=example-client-secret
TAILSCALE_TAILNET=example.test
ALERT_WEBHOOK_URL=http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/1/example-token
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
run-host-drift-check: the run never took the prod lock
run-host-drift-check: posted the failed alert
EOF
  diff /dev/null "$tree/calls"
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    diff - "$tree/discord/bodies/1.json"
  assert_status 1 "$status"
}

it_fails_before_the_check_and_posts_when_a_credential_is_missing() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  cat > "$tree/credentials/drift-check" << EOF
PULUMI_BACKEND_URL=s3://example-state?endpoint=state.example.test
AWS_ACCESS_KEY_ID=example-key-id
AWS_SECRET_ACCESS_KEY=example-secret
PULUMI_CONFIG_PASSPHRASE=
CLOUDFLARE_API_TOKEN=example-cloudflare-token
TAILSCALE_OAUTH_CLIENT_ID=example-client-id
TAILSCALE_OAUTH_CLIENT_SECRET=example-client-secret
ALERT_WEBHOOK_URL=http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/1/example-token
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
run-host-drift-check: the credentials file has no PULUMI_CONFIG_PASSPHRASE TAILSCALE_TAILNET
run-host-drift-check: posted the failed alert
EOF
  diff /dev/null "$tree/calls"
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    diff - "$tree/discord/bodies/1.json"
  assert_status 1 "$status"
}

it_fails_before_the_check_without_printing_the_line_when_a_line_holds_an_unknown_name() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  cat > "$tree/credentials/drift-check" << EOF
ALERT_WEBHOOK_URL=http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/1/example-token
ONIDEL_API_KEY=example-onidel-key
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
run-host-drift-check: line 2 of the credentials file holds no known name
run-host-drift-check: posted the failed alert
EOF
  diff /dev/null "$tree/calls"
  diff - "$tree/discord/requests" <<< 'POST /api/webhooks/1/example-token'
  assert_status 1 "$status"
}

it_fails_before_the_check_and_says_the_alert_failed_without_a_credentials_file() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << EOF
run-host-drift-check: no credentials file at $tree/credentials/drift-check
alert-scheduled-drift: ALERT_WEBHOOK_URL is empty
run-host-drift-check: the alert failed (exit 1)
EOF
  diff /dev/null "$tree/calls"
  assert_missing "$tree/discord/requests" "an alert was posted"
  assert_status 1 "$status"
}

it_refuses_to_run_without_its_invocation_id() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    RUN_HOST=geoffcloud LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'run-host-drift-check: set INVOCATION_ID'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

it_rejects_an_argument_with_its_usage() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" --dry-run > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: run-host-drift-check.sh'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/answers" "$tree/credentials" "$tree/discord"
  : > "$tree/calls"
  create_stub_scripted_command "$tree/bin" pulumi
  create_stub_timeout "$tree/bin"
  start_stub_discord_webhook "$tree/discord"
}

run_cases
