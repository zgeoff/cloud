#!/usr/bin/env bash
# Hermetic test for install-drift-check-credentials.sh: it reads the drift check's nine values
# from 1Password, refuses an empty value or one with a line break, and on the host writes the
# credentials file atomically, mode 0400, in a directory of mode 0700 that it creates. It touches
# no host and no 1Password vault: op and ssh are stand-ins from test-support/shell that log their
# argv as JSON lines, op reads the case's vault directory, and "the host" is a directory in the
# case's tree, where the ssh stand-in runs the script's remote command. Failures that real state
# can reach run on real state: a directory that is not a mount point and ssh refused by a dead
# loopback port. Each case runs the script under `env -i` with only the variables it sets and
# compares its whole stdout, stderr, call log and the files it leaves, and its exact exit code.
# The ssh call is written out as literal text, masking only the case's temporary path as TREE.
#
#   bash scripts/test-install-drift-check-credentials.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-op-read.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-bash-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/require-remote-tool-stubs.sh"

it_installs_the_credentials_over_ssh_stdin_in_a_directory_it_creates() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/r2-pulumi-state-read" "$tree/vault/cloud/pulumi-passphrase" \
    "$tree/vault/cloud/cloudflare-read" "$tree/vault/cloud/tailscale-read" "$tree/vault/cloud/alert-webhook"
  printf '%s' 's3://example-state?endpoint=state.example.test' > "$tree/vault/cloud/r2-pulumi-state-read/backend-url"
  printf '%s' example-key-id > "$tree/vault/cloud/r2-pulumi-state-read/access-key-id"
  printf '%s' 'example-secret=with-equals' > "$tree/vault/cloud/r2-pulumi-state-read/secret-access-key"
  printf '%s' 'example passphrase' > "$tree/vault/cloud/pulumi-passphrase/credential"
  printf '%s' example-cloudflare-token > "$tree/vault/cloud/cloudflare-read/credential"
  printf '%s' example-client-id > "$tree/vault/cloud/tailscale-read/client-id"
  printf '%s' example-client-secret > "$tree/vault/cloud/tailscale-read/client-secret"
  printf '%s' example.test > "$tree/vault/cloud/tailscale-read/tailnet"
  printf '%s' https://discord.example/api/webhooks/1/example-token > "$tree/vault/cloud/alert-webhook/credential"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" DRIFT_CHECK_SECRETS_MOUNT= \
    DRIFT_CHECK_CREDENTIALS_FILE="$tree/host/secrets/drift-check/credentials" \
    bash install-drift-check-credentials.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" <<< "installed: $tree/host/secrets/drift-check/credentials (9 lines, mode 400)"
  sed "s|$tree|TREE|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << 'CALLS'
["op","read","--no-newline","op://cloud/r2-pulumi-state-read/backend-url"]
["op","read","--no-newline","op://cloud/r2-pulumi-state-read/access-key-id"]
["op","read","--no-newline","op://cloud/r2-pulumi-state-read/secret-access-key"]
["op","read","--no-newline","op://cloud/pulumi-passphrase/credential"]
["op","read","--no-newline","op://cloud/cloudflare-read/credential"]
["op","read","--no-newline","op://cloud/tailscale-read/client-id"]
["op","read","--no-newline","op://cloud/tailscale-read/client-secret"]
["op","read","--no-newline","op://cloud/tailscale-read/tailnet"]
["op","read","--no-newline","op://cloud/alert-webhook/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","bash -c $'set -euo pipefail\\nfile=$1\\nif [ -n \"$2\" ] && ! mountpoint -q \"$2\"; then\\n  echo \"$2 is not a mount point; nothing changed\" >&2\\n  exit 1\\nfi\\numask 077\\nmkdir -p \"$(dirname \"$file\")\"\\ntmp=$(mktemp \"$file.XXXXXX\")\\ntrap \"rm -f \\\\\"$tmp\\\\\"\" EXIT\\ncat > \"$tmp\"\\nchmod 0400 \"$tmp\"\\nchown 0:0 \"$tmp\" 2>/dev/null || true\\nmv -f \"$tmp\" \"$file\"\\ntrap - EXIT\\necho \"installed: $file ($(wc -l < \"$file\") lines, mode $(stat -c %a \"$file\"))\"' _ TREE/host/secrets/drift-check/credentials ''"]
CALLS
  diff - "$tree/host/secrets/drift-check/credentials" << 'FILE'
PULUMI_BACKEND_URL=s3://example-state?endpoint=state.example.test
AWS_ACCESS_KEY_ID=example-key-id
AWS_SECRET_ACCESS_KEY=example-secret=with-equals
PULUMI_CONFIG_PASSPHRASE=example passphrase
CLOUDFLARE_API_TOKEN=example-cloudflare-token
TAILSCALE_OAUTH_CLIENT_ID=example-client-id
TAILSCALE_OAUTH_CLIENT_SECRET=example-client-secret
TAILSCALE_TAILNET=example.test
ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/1/example-token
FILE
  stat -c '%a %n' "$tree/host/secrets/drift-check" "$tree/host/secrets/drift-check/credentials" | sed "s|$tree|TREE|g" > "$tree/modes"
  diff - "$tree/modes" << 'MODES'
700 TREE/host/secrets/drift-check
400 TREE/host/secrets/drift-check/credentials
MODES
  assert_status 0 "$status"
}

it_replaces_a_credentials_file_it_installed_before_from_the_named_vault() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/staging/r2-pulumi-state-read" "$tree/vault/staging/pulumi-passphrase" \
    "$tree/vault/staging/cloudflare-read" "$tree/vault/staging/tailscale-read" "$tree/vault/staging/alert-webhook" \
    "$tree/host/secrets/drift-check"
  printf '%s' 's3://example-state?endpoint=state.example.test' > "$tree/vault/staging/r2-pulumi-state-read/backend-url"
  printf '%s' new-key-id > "$tree/vault/staging/r2-pulumi-state-read/access-key-id"
  printf '%s' new-secret > "$tree/vault/staging/r2-pulumi-state-read/secret-access-key"
  printf '%s' new-passphrase > "$tree/vault/staging/pulumi-passphrase/credential"
  printf '%s' new-cloudflare-token > "$tree/vault/staging/cloudflare-read/credential"
  printf '%s' new-client-id > "$tree/vault/staging/tailscale-read/client-id"
  printf '%s' new-client-secret > "$tree/vault/staging/tailscale-read/client-secret"
  printf '%s' example.test > "$tree/vault/staging/tailscale-read/tailnet"
  printf '%s' https://discord.example/api/webhooks/2/new-token > "$tree/vault/staging/alert-webhook/credential"
  printf 'AWS_ACCESS_KEY_ID=old-key-id\n' > "$tree/host/secrets/drift-check/credentials"
  chmod 0400 "$tree/host/secrets/drift-check/credentials"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    DRIFT_CHECK_HOST=local DRIFT_CHECK_VAULT=staging DRIFT_CHECK_SECRETS_MOUNT= \
    DRIFT_CHECK_CREDENTIALS_FILE="$tree/host/secrets/drift-check/credentials" \
    bash install-drift-check-credentials.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" <<< "installed: $tree/host/secrets/drift-check/credentials (9 lines, mode 400)"
  diff - "$tree/host/secrets/drift-check/credentials" << 'FILE'
PULUMI_BACKEND_URL=s3://example-state?endpoint=state.example.test
AWS_ACCESS_KEY_ID=new-key-id
AWS_SECRET_ACCESS_KEY=new-secret
PULUMI_CONFIG_PASSPHRASE=new-passphrase
CLOUDFLARE_API_TOKEN=new-cloudflare-token
TAILSCALE_OAUTH_CLIENT_ID=new-client-id
TAILSCALE_OAUTH_CLIENT_SECRET=new-client-secret
TAILSCALE_TAILNET=example.test
ALERT_WEBHOOK_URL=https://discord.example/api/webhooks/2/new-token
FILE
  ls -A "$tree/host/secrets/drift-check" > "$tree/files"
  diff - "$tree/files" <<< credentials
  assert_status 0 "$status"
}

it_stops_with_exit_1_and_changes_nothing_when_a_value_holds_a_line_break() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/r2-pulumi-state-read"
  printf '%s' 's3://example-state?endpoint=state.example.test' > "$tree/vault/cloud/r2-pulumi-state-read/backend-url"
  printf 'example-key-id\nAWS_REGION=elsewhere' > "$tree/vault/cloud/r2-pulumi-state-read/access-key-id"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    DRIFT_CHECK_HOST=local DRIFT_CHECK_SECRETS_MOUNT= \
    DRIFT_CHECK_CREDENTIALS_FILE="$tree/host/secrets/drift-check/credentials" \
    bash install-drift-check-credentials.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the value at op://cloud/r2-pulumi-state-read/access-key-id is empty or holds a line break; nothing changed'
  diff - "$tree/calls" << 'CALLS'
["op","read","--no-newline","op://cloud/r2-pulumi-state-read/backend-url"]
["op","read","--no-newline","op://cloud/r2-pulumi-state-read/access-key-id"]
CALLS
  ls -A "$tree/host/secrets" > "$tree/files"
  diff /dev/null "$tree/files"
  assert_status 1 "$status"
}

it_stops_with_exit_1_and_changes_nothing_when_a_value_is_empty() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/r2-pulumi-state-read"
  : > "$tree/vault/cloud/r2-pulumi-state-read/backend-url"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    DRIFT_CHECK_HOST=local DRIFT_CHECK_SECRETS_MOUNT= \
    DRIFT_CHECK_CREDENTIALS_FILE="$tree/host/secrets/drift-check/credentials" \
    bash install-drift-check-credentials.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the value at op://cloud/r2-pulumi-state-read/backend-url is empty or holds a line break; nothing changed'
  diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud/r2-pulumi-state-read/backend-url"]'
  ls -A "$tree/host/secrets" > "$tree/files"
  diff /dev/null "$tree/files"
  assert_status 1 "$status"
}

it_stops_with_op_exit_1_and_changes_nothing_when_an_item_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    DRIFT_CHECK_HOST=local DRIFT_CHECK_SECRETS_MOUNT= \
    DRIFT_CHECK_CREDENTIALS_FILE="$tree/host/secrets/drift-check/credentials" \
    bash install-drift-check-credentials.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  sed -E 's/^\[ERROR\] [0-9/]+ [0-9:]+ /[ERROR] DATE /' "$tree/err" > "$tree/err-masked"
  diff - "$tree/err-masked" <<< '[ERROR] DATE could not read secret op://cloud/r2-pulumi-state-read/backend-url: could not get item cloud/r2-pulumi-state-read: "r2-pulumi-state-read" isn'\''t an item in the "cloud" vault.'
  diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud/r2-pulumi-state-read/backend-url"]'
  ls -A "$tree/host/secrets" > "$tree/files"
  diff /dev/null "$tree/files"
  assert_status 1 "$status"
}

it_refuses_and_writes_nothing_when_the_secrets_directory_is_not_a_mount_point() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/r2-pulumi-state-read" "$tree/vault/cloud/pulumi-passphrase" \
    "$tree/vault/cloud/cloudflare-read" "$tree/vault/cloud/tailscale-read" "$tree/vault/cloud/alert-webhook"
  printf '%s' 's3://example-state?endpoint=state.example.test' > "$tree/vault/cloud/r2-pulumi-state-read/backend-url"
  printf '%s' example-key-id > "$tree/vault/cloud/r2-pulumi-state-read/access-key-id"
  printf '%s' example-secret > "$tree/vault/cloud/r2-pulumi-state-read/secret-access-key"
  printf '%s' example-passphrase > "$tree/vault/cloud/pulumi-passphrase/credential"
  printf '%s' example-cloudflare-token > "$tree/vault/cloud/cloudflare-read/credential"
  printf '%s' example-client-id > "$tree/vault/cloud/tailscale-read/client-id"
  printf '%s' example-client-secret > "$tree/vault/cloud/tailscale-read/client-secret"
  printf '%s' example.test > "$tree/vault/cloud/tailscale-read/tailnet"
  printf '%s' https://discord.example/api/webhooks/1/example-token > "$tree/vault/cloud/alert-webhook/credential"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    DRIFT_CHECK_HOST=local DRIFT_CHECK_SECRETS_MOUNT="$tree/host/secrets" \
    DRIFT_CHECK_CREDENTIALS_FILE="$tree/host/secrets/drift-check/credentials" \
    bash install-drift-check-credentials.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$tree/host/secrets is not a mount point; nothing changed"
  ls -A "$tree/host/secrets" > "$tree/files"
  diff /dev/null "$tree/files"
  assert_status 1 "$status"
}

it_fails_with_ssh_exit_255_and_changes_nothing_when_the_host_refuses_the_connection() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/r2-pulumi-state-read" "$tree/vault/cloud/pulumi-passphrase" \
    "$tree/vault/cloud/cloudflare-read" "$tree/vault/cloud/tailscale-read" "$tree/vault/cloud/alert-webhook"
  printf '%s' 's3://example-state?endpoint=state.example.test' > "$tree/vault/cloud/r2-pulumi-state-read/backend-url"
  printf '%s' example-key-id > "$tree/vault/cloud/r2-pulumi-state-read/access-key-id"
  printf '%s' example-secret > "$tree/vault/cloud/r2-pulumi-state-read/secret-access-key"
  printf '%s' example-passphrase > "$tree/vault/cloud/pulumi-passphrase/credential"
  printf '%s' example-cloudflare-token > "$tree/vault/cloud/cloudflare-read/credential"
  printf '%s' example-client-id > "$tree/vault/cloud/tailscale-read/client-id"
  printf '%s' example-client-secret > "$tree/vault/cloud/tailscale-read/client-secret"
  printf '%s' example.test > "$tree/vault/cloud/tailscale-read/tailnet"
  printf '%s' https://discord.example/api/webhooks/1/example-token > "$tree/vault/cloud/alert-webhook/credential"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 DRIFT_CHECK_HOST=ssh://root@127.0.0.1:1 DRIFT_CHECK_SECRETS_MOUNT= \
    DRIFT_CHECK_CREDENTIALS_FILE="$tree/host/secrets/drift-check/credentials" \
    bash install-drift-check-credentials.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  tail -n 1 "$tree/calls" | jq -r '.[3]' > "$tree/destination"
  diff - "$tree/destination" <<< 'ssh://root@127.0.0.1:1'
  ls -A "$tree/host/secrets" > "$tree/files"
  diff /dev/null "$tree/files"
  assert_status 255 "$status"
}

# Runtime every case needs: the script in <tree>, the op and ssh stand-ins with fail-closed
# stand-ins for the other remote tools in <tree>/bin, the host's PATH stand-ins in
# <tree>/host-bin, each checked so no call can reach a real remote tool, the empty call log,
# the host's secrets directory, and the HOME and TMPDIR the script runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/host-bin" "$tree/home" "$tree/tmp" "$tree/host/secrets"
  : > "$tree/calls"
  cp "$(dirname "${BASH_SOURCE[0]}")/install-drift-check-credentials.sh" "$tree/"
  create_stub_op_read "$tree/bin"
  create_stub_bash_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  create_stub_remote_tools "$tree/host-bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
  require_remote_tool_stubs "$tree/host-bin"
}

run_cases
