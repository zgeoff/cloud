#!/usr/bin/env bats
# bats file_tags=suite:scripts
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
# hold-prod-lock.bats tests the wait for the lock. Each case runs the script under `env -i` and
# compares its whole stdout, stderr, call logs and posted bodies.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-scripted-command.sh'
  load 'src/test-utils/shell/create-stub-timeout.sh'
  load 'src/test-utils/shell/start-stub-discord-webhook.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/run-host-drift-check.sh"
  check="$BATS_TEST_DIRNAME/check-scheduled-drift.sh"
  infra="$(cd "$BATS_TEST_DIRNAME/../infra" && pwd)"
  logged_env='PULUMI_BACKEND_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION PULUMI_CONFIG_PASSPHRASE CLOUDFLARE_API_TOKEN TAILSCALE_OAUTH_CLIENT_ID TAILSCALE_OAUTH_CLIENT_SECRET TAILSCALE_TAILNET ALERT_WEBHOOK_URL'
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
  kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/answers" "$tree/credentials" "$tree/discord"
  : > "$tree/calls"
  create_stub_scripted_command "$tree/bin" pulumi
  create_stub_timeout "$tree/bin"
  start_stub_discord_webhook "$tree/discord"
}

@test "it runs the check with every credential but the webhook and posts nothing when it finds no drift" {
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

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" STUB_LOG_ENV="$logged_env" \
    STUB_TIMEOUT_LOG="$tree/timeout-calls" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  assert_output - << 'EOF'
Resources:
    61 unchanged
run-host-drift-check: no drift
EOF
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
{"cwd":"$infra","argv":["pulumi","refresh","--stack","prod","--preview-only","--expect-no-changes","--non-interactive","--exclude","urn:pulumi:prod::geoff-cloud::**onidel:index:**","--exclude","urn:pulumi:prod::geoff-cloud::**kubernetes:**","--suppress-outputs"],"env":{"PULUMI_BACKEND_URL":"s3://example-state?endpoint=state.example.test","AWS_ACCESS_KEY_ID":"example-key-id","AWS_SECRET_ACCESS_KEY":"example-secret=with-equals","AWS_REGION":"auto","PULUMI_CONFIG_PASSPHRASE":"example passphrase","CLOUDFLARE_API_TOKEN":"example-cloudflare-token","TAILSCALE_OAUTH_CLIENT_ID":"example-client-id","TAILSCALE_OAUTH_CLIENT_SECRET":"example-client-secret","TAILSCALE_TAILNET":"example.test"}}
EOF
  run -0 diff - "$tree/timeout-calls" << EOF
["timeout","2700","bash","$check","--suppress-outputs"]
EOF
  refute [ -e "$tree/discord/requests" ]
}

@test "it posts that the check found drift and exits 7 when the refresh finds a change" {
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

  run -7 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  assert_output - << 'EOF'
Resources:
    ~ 1 to update
    60 unchanged
error: no changes were expected for refresh but changes were proposed
EOF
  assert_stderr 'run-host-drift-check: posted the drift alert'

  run -0 diff - "$tree/discord/requests" <<< 'POST /api/webhooks/1/example-token'
  printf '%s' '{  "content": "The scheduled drift check found drift in prod: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    run -0 diff - "$tree/discord/bodies/1.json"
}

@test "it posts that the check failed and exits with the refresh s status when the refresh fails" {
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

  run -255 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  assert_output 'error: failed to load checkpoint: blob (key ".pulumi/stacks/geoff-cloud/prod.json") (code=Unknown): AccessDenied'
  assert_stderr 'run-host-drift-check: posted the failed alert'

  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    run -0 diff - "$tree/discord/bodies/1.json"
}

@test "it posts that the check failed when a provider plugin cannot start" {
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

  run -255 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  assert_output 'error: could not load provider for resource urn:pulumi:prod::geoff-cloud::example:index:Thing::example: failed to load plugin /var/lib/example/plugins/resource-example-v1.2.3/pulumi-resource-example: fork/exec /var/lib/example/plugins/resource-example-v1.2.3/pulumi-resource-example: permission denied'
  assert_stderr 'run-host-drift-check: posted the failed alert'

  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    run -0 diff - "$tree/discord/bodies/1.json"
}

@test "it posts that the run failed when a step without its own alert fails" {
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
  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/missing" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  refute_output
  assert_stderr - << EOF
mktemp: failed to create file via template '$tree/missing/tmp.XXXXXXXXXX': No such file or directory
run-host-drift-check: the run failed (exit 1)
run-host-drift-check: posted the failed alert
EOF

  run -0 diff /dev/null "$tree/calls"
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    run -0 diff - "$tree/discord/bodies/1.json"
}

@test "it posts that the check failed and exits 124 when the check runs out of time" {
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

  run -124 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" STUB_TIMEOUT_LOG="$tree/timeout-calls" \
    STUB_TIMEOUT_EXPIRE=124 CREDENTIALS_DIRECTORY="$tree/credentials" CHECK_TIMEOUT=60 \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  refute_output
  assert_stderr 'run-host-drift-check: posted the failed alert'

  run -0 diff /dev/null "$tree/calls"
  run -0 diff - "$tree/timeout-calls" << EOF
["timeout","60","bash","$check","--suppress-outputs"]
EOF
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    run -0 diff - "$tree/discord/bodies/1.json"
}

@test "it keeps the check s status and says so when the alert fails" {
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

  run -7 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  assert_output - << 'EOF'
Resources:
    ~ 1 to update
EOF
  assert_stderr - << 'EOF'
curl: (22) The requested URL returned error: 404
run-host-drift-check: the alert failed (exit 22)
EOF

  run -0 diff - "$tree/discord/requests" <<< 'POST /api/webhooks/1/example-token'
}

@test "it fails before the check and posts the failed alert not drift when a deploy prod run held the lock past the wait" {
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

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" STUB_TIMEOUT_LOG="$tree/timeout-calls" \
    CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  refute_output
  assert_stderr - << 'EOF'
run-host-drift-check: a Deploy prod run held the prod lock past the wait
run-host-drift-check: posted the failed alert
EOF

  run -0 diff /dev/null "$tree/calls"
  refute [ -e "$tree/timeout-calls" ]
  run -0 diff - "$tree/discord/requests" <<< 'POST /api/webhooks/1/example-token'
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    run -0 diff - "$tree/discord/bodies/1.json"
}

@test "it fails before the check and posts when taking the lock failed" {
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

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  refute_output
  assert_stderr - << 'EOF'
run-host-drift-check: taking the prod lock failed (exit 1)
run-host-drift-check: posted the failed alert
EOF

  run -0 diff /dev/null "$tree/calls"
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    run -0 diff - "$tree/discord/bodies/1.json"
}

@test "it fails before the check and posts when the run never took the lock" {
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

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  refute_output
  assert_stderr - << 'EOF'
run-host-drift-check: the run never took the prod lock
run-host-drift-check: posted the failed alert
EOF

  run -0 diff /dev/null "$tree/calls"
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    run -0 diff - "$tree/discord/bodies/1.json"
}

@test "it fails before the check and posts when a credential is missing" {
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

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  refute_output
  assert_stderr - << 'EOF'
run-host-drift-check: the credentials file has no PULUMI_CONFIG_PASSPHRASE TAILSCALE_TAILNET
run-host-drift-check: posted the failed alert
EOF

  run -0 diff /dev/null "$tree/calls"
  printf '%s' '{  "content": "The scheduled drift check failed: on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9"}' |
    run -0 diff - "$tree/discord/bodies/1.json"
}

@test "it fails before the check without printing the line when a line holds an unknown name" {
  setup_test "$tree"
  cat > "$tree/credentials/drift-check" << EOF
ALERT_WEBHOOK_URL=http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/1/example-token
ONIDEL_API_KEY=example-onidel-key
EOF

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  refute_output
  assert_stderr - << 'EOF'
run-host-drift-check: line 2 of the credentials file holds no known name
run-host-drift-check: posted the failed alert
EOF

  run -0 diff /dev/null "$tree/calls"
  run -0 diff - "$tree/discord/requests" <<< 'POST /api/webhooks/1/example-token'
}

@test "it fails before the check and says the alert failed without a credentials file" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  refute_output
  assert_stderr - << EOF
run-host-drift-check: no credentials file at $tree/credentials/drift-check
alert-scheduled-drift: ALERT_WEBHOOK_URL is empty
run-host-drift-check: the alert failed (exit 1)
EOF

  run -0 diff /dev/null "$tree/calls"
  refute [ -e "$tree/discord/requests" ]
}

@test "it refuses to run without its invocation id" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    RUN_HOST=geoffcloud LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script"

  refute_output
  assert_stderr 'run-host-drift-check: set INVOCATION_ID'

  run -0 diff /dev/null "$tree/calls"
}

@test "it rejects an argument with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" CREDENTIALS_DIRECTORY="$tree/credentials" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 RUN_HOST=geoffcloud \
    LOCK_STATUS_FILE="$tree/lock-status" \
    bash "$script" --dry-run

  refute_output
  assert_stderr 'usage: run-host-drift-check.sh'

  run -0 diff /dev/null "$tree/calls"
}
