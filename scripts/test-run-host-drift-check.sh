#!/usr/bin/env bash
# Test for run-host-drift-check.sh: it runs the real check-scheduled-drift.sh with every credential
# but the webhook in its environment, under timeout, and posts nothing when the check finds no
# drift; it posts drift, a failed refresh and a check that ran out of time through the real
# alert-scheduled-drift.sh, and keeps the check's status when the alert fails; it waits while a
# Deploy prod run is queued or in progress, fails after its last ask, and checks anyway when GitHub
# does not answer; it checks once more when a Deploy prod run overlapped a check that failed, and
# reports that second check; and it fails before the check on a missing credentials file, a missing
# credential, a line with an unknown name, a missing input or an argument.
#
# pulumi is create-stub-scripted-command.sh, which logs the credentials it receives; timeout is
# create-stub-timeout.sh; the pause is create-stub-clock.sh's sleep, first on PATH; and Discord is
# start-stub-discord-webhook.sh on loopback, which the real curl posts to. GitHub's answers are
# files the real curl reads through file:// URLs, and a GitHub that does not answer is a dead
# loopback port. The case that waits for a run to end gets GitHub's two answers from a scripted
# curl instead, since the answers change between asks. Each case runs the script under `env -i`
# and compares its whole stdout, stderr, call logs and posted bodies.
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
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-one-of-outputs.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-clock.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-scripted-command.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-timeout.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/start-stub-discord-webhook.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-host-drift-check.sh"
check="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-scheduled-drift.sh"
infra="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra" && pwd)"
logged_env='PULUMI_BACKEND_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION PULUMI_CONFIG_PASSPHRASE CLOUDFLARE_API_TOKEN TAILSCALE_OAUTH_CLIENT_ID TAILSCALE_OAUTH_CLIENT_SECRET TAILSCALE_TAILNET ALERT_WEBHOOK_URL'
runs_path='repos/example/cloud/actions/workflows/deploy-prod.yml/runs'

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
  echo '{"total_count":2,"workflow_runs":[{"status":"completed"},{"status":"waiting"}]}' > "$tree/github/$runs_path"
  printf 'Resources:\n    61 unchanged\n' > "$tree/answers/1.out"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" STUB_LOG_ENV="$logged_env" \
    STUB_TIMEOUT_LOG="$tree/timeout-calls" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL="file://$tree/github" REPO=example/cloud \
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
  assert_missing "$tree/clock/pauses" "the run paused"
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
  echo '{"total_count":1,"workflow_runs":[{"status":"completed"}]}' > "$tree/github/$runs_path"
  printf 'Resources:\n    ~ 1 to update\n    60 unchanged\n' > "$tree/answers/1.out"
  printf 'error: no changes were expected for refresh but changes were proposed\n' > "$tree/answers/1.err"
  echo 7 > "$tree/answers/1.status"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL="file://$tree/github" REPO=example/cloud \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
Resources:
    ~ 1 to update
    60 unchanged
error: no changes were expected for refresh but changes were proposed
EOF
  diff /dev/null "$tree/err"
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
  echo '{"total_count":1,"workflow_runs":[{"status":"completed"}]}' > "$tree/github/$runs_path"
  printf 'error: failed to load checkpoint: blob (key ".pulumi/stacks/geoff-cloud/prod.json") (code=Unknown): AccessDenied\n' > "$tree/answers/1.err"
  echo 255 > "$tree/answers/1.status"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL="file://$tree/github" REPO=example/cloud \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'error: failed to load checkpoint: blob (key ".pulumi/stacks/geoff-cloud/prod.json") (code=Unknown): AccessDenied'
  diff /dev/null "$tree/err"
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    diff - "$tree/discord/bodies/1.json"
  assert_status 255 "$status"
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
  echo '{"total_count":1,"workflow_runs":[{"status":"completed"}]}' > "$tree/github/$runs_path"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" STUB_TIMEOUT_LOG="$tree/timeout-calls" \
    STUB_TIMEOUT_EXPIRE=124 CREDENTIALS_DIRECTORY="$tree/credentials" CHECK_TIMEOUT=60 \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL="file://$tree/github" REPO=example/cloud \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
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
  echo '{"total_count":1,"workflow_runs":[{"status":"completed"}]}' > "$tree/github/$runs_path"
  printf 'Resources:\n    ~ 1 to update\n' > "$tree/answers/1.out"
  echo 7 > "$tree/answers/1.status"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL="file://$tree/github" REPO=example/cloud \
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

it_waits_while_a_deploy_prod_run_is_in_progress_and_checks_once_it_ends() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree" scripted-curl
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
  echo '{"total_count":2,"workflow_runs":[{"status":"in_progress"},{"status":"completed"}]}' > "$tree/curl-answers/1.out"
  echo '{"total_count":2,"workflow_runs":[{"status":"completed"},{"status":"completed"}]}' > "$tree/curl-answers/2.out"
  printf 'Resources:\n    61 unchanged\n' > "$tree/answers/1.out"

  (cd "$tree" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL=https://api.github.test REPO=example/cloud \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
Resources:
    61 unchanged
run-host-drift-check: no drift
EOF
  diff - "$tree/err" <<< 'run-host-drift-check: a Deploy prod run is in progress; asking again in 300s'
  diff - "$tree/curl-calls" << EOF
{"cwd":"$tree","argv":["curl","-fsS","--max-time","30","https://api.github.test/repos/example/cloud/actions/workflows/deploy-prod.yml/runs?per_page=20"]}
{"cwd":"$tree","argv":["curl","-fsS","--max-time","30","https://api.github.test/repos/example/cloud/actions/workflows/deploy-prod.yml/runs?per_page=20"]}
EOF
  diff - "$tree/clock/pauses" <<< '300'
  assert_status 0 "$status"
}

it_checks_again_and_posts_nothing_when_a_deploy_prod_run_overlapped_a_check_that_found_drift() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree" scripted-curl
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
  echo '{"total_count":1,"workflow_runs":[{"status":"completed","updated_at":"2000-01-01T00:00:00Z"}]}' > "$tree/curl-answers/1.out"
  echo '{"total_count":1,"workflow_runs":[{"status":"completed","updated_at":"2999-01-01T00:00:00Z"}]}' > "$tree/curl-answers/2.out"
  echo '{"total_count":1,"workflow_runs":[{"status":"completed","updated_at":"2999-01-01T00:00:00Z"}]}' > "$tree/curl-answers/3.out"
  printf 'Resources:\n    ~ 1 to update\n' > "$tree/answers/1.out"
  echo 7 > "$tree/answers/1.status"
  printf 'Resources:\n    61 unchanged\n' > "$tree/answers/2.out"

  (cd "$tree" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL=https://api.github.test REPO=example/cloud \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
Resources:
    ~ 1 to update
Resources:
    61 unchanged
run-host-drift-check: no drift
EOF
  diff - "$tree/err" <<< 'run-host-drift-check: a Deploy prod run overlapped the check; checking again once it ends'
  diff - "$tree/curl-calls" << EOF
{"cwd":"$tree","argv":["curl","-fsS","--max-time","30","https://api.github.test/repos/example/cloud/actions/workflows/deploy-prod.yml/runs?per_page=20"]}
{"cwd":"$tree","argv":["curl","-fsS","--max-time","30","https://api.github.test/repos/example/cloud/actions/workflows/deploy-prod.yml/runs?per_page=20"]}
{"cwd":"$tree","argv":["curl","-fsS","--max-time","30","https://api.github.test/repos/example/cloud/actions/workflows/deploy-prod.yml/runs?per_page=20"]}
EOF
  assert_missing "$tree/discord/requests" "an alert was posted"
  assert_status 0 "$status"
}

it_posts_the_second_check_s_drift_when_a_deploy_prod_run_overlapped_both_checks() {
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
  echo '{"total_count":1,"workflow_runs":[{"status":"completed","updated_at":"2999-01-01T00:00:00Z"}]}' > "$tree/github/$runs_path"
  printf 'Resources:\n    ~ 1 to update\n' > "$tree/answers/1.out"
  echo 7 > "$tree/answers/1.status"
  printf 'Resources:\n    ~ 2 to update\n' > "$tree/answers/2.out"
  echo 7 > "$tree/answers/2.status"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL="file://$tree/github" REPO=example/cloud \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
Resources:
    ~ 1 to update
Resources:
    ~ 2 to update
EOF
  diff - "$tree/err" <<< 'run-host-drift-check: a Deploy prod run overlapped the check; checking again once it ends'
  printf '%s' '{  "content": "The scheduled drift check found drift in prod: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    diff - "$tree/discord/bodies/1.json"
  assert_status 7 "$status"
}

it_fails_and_posts_after_its_last_ask_when_a_deploy_prod_run_stays_queued() {
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
  echo '{"total_count":1,"workflow_runs":[{"status":"queued"}]}' > "$tree/github/$runs_path"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    DEPLOY_WAIT_ATTEMPTS=3 DEPLOY_WAIT_DELAY=120 \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL="file://$tree/github" REPO=example/cloud \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
run-host-drift-check: a Deploy prod run is in progress; asking again in 120s
run-host-drift-check: a Deploy prod run is in progress; asking again in 120s
run-host-drift-check: a Deploy prod run was still in progress after 3 asks
EOF
  diff /dev/null "$tree/calls"
  diff - "$tree/clock/pauses" << 'EOF'
120
120
EOF
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    diff - "$tree/discord/bodies/1.json"
  assert_status 1 "$status"
}

it_checks_anyway_when_github_does_not_answer() {
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
  printf 'Resources:\n    61 unchanged\n' > "$tree/answers/1.out"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL=http://127.0.0.1:1 REPO=example/cloud \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
Resources:
    61 unchanged
run-host-drift-check: no drift
EOF
  sed 's/after [0-9]* ms/after <ms> ms/' "$tree/err" > "$tree/err.masked"
  printf 'Resources:\n    61 unchanged\nrun-host-drift-check: no drift\n' > "$tree/out.expected"
  # curl's connect error differs between Ubuntu 24.04's curl 8.5.0, which CI runs, and curl 8.22.0
  cat > "$tree/err.curl-8.5" << 'EOF'
curl: (7) Failed to connect to 127.0.0.1 port 1 after <ms> ms: Couldn't connect to server
run-host-drift-check: GitHub did not list the Deploy prod runs; checking anyway
EOF
  cat > "$tree/err.curl-8.22" << 'EOF'
curl: (7) Failed to connect to 127.0.0.1:1 after <ms> ms: Could not connect to server
run-host-drift-check: GitHub did not list the Deploy prod runs; checking anyway
EOF
  assert_one_of_outputs "the check without GitHub" "$tree/out" "$tree/err.masked" "$status" \
    'curl 8.5.0' "$tree/out.expected" "$tree/err.curl-8.5" 0 \
    'curl 8.22.0' "$tree/out.expected" "$tree/err.curl-8.22" 0
  assert_missing "$tree/discord/requests" "an alert was posted"
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

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL="file://$tree/github" REPO=example/cloud \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'run-host-drift-check: the credentials file has no PULUMI_CONFIG_PASSPHRASE TAILSCALE_TAILNET'
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

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL="file://$tree/github" REPO=example/cloud \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'run-host-drift-check: line 2 of the credentials file holds no known name'
  diff /dev/null "$tree/calls"
  diff - "$tree/discord/requests" <<< 'POST /api/webhooks/1/example-token'
  assert_status 1 "$status"
}

it_fails_before_the_check_and_says_the_alert_failed_without_a_credentials_file() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL="file://$tree/github" REPO=example/cloud \
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

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    RUN_HOST=geoffcloud GITHUB_API_URL="file://$tree/github" REPO=example/cloud \
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

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    GITHUB_API_URL="file://$tree/github" REPO=example/cloud \
    bash "$script" --dry-run > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: run-host-drift-check.sh'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

# setup_test <tree> [scripted-curl]: scripted-curl puts a scripted curl, which answers from
# <tree>/curl-answers and logs to <tree>/curl-calls, before the real one
setup_test() {
  local tree="$1" wiring="${2:-}"
  mkdir -p "$tree/bin" "$tree/clock" "$tree/home" "$tree/tmp" "$tree/answers" "$tree/credentials" \
    "$tree/discord" "$tree/github/$(dirname "$runs_path")"
  : > "$tree/calls"
  create_stub_clock "$tree/clock"
  create_stub_scripted_command "$tree/bin" pulumi
  create_stub_timeout "$tree/bin"
  if [ "$wiring" = scripted-curl ]; then
    mkdir "$tree/curl-answers"
    create_stub_scripted_command "$tree/bin" curl "$tree/curl-calls" "$tree/curl-answers"
  fi
  start_stub_discord_webhook "$tree/discord"
}

run_cases
