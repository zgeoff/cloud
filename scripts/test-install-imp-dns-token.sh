#!/usr/bin/env bash
# Hermetic test for install-imp-dns-token.sh: it reads imp's Cloudflare DNS token and ACME
# email from 1Password, refuses values that do not look like either, and on the host writes
# the token file and rewrites the env file, each atomically and mode 0400, keeping every
# other env line. It touches no host and no 1Password vault: op and ssh are stand-ins from
# test-lib that log their argv as JSON lines, op reads the case's vault directory, and "the
# host" is a directory in the case's tree, where the ssh stand-in runs the script's remote
# command. Failures that real state can reach run on real state: a secrets directory the
# script may not write, an env file that is not there, and ssh refused by a dead loopback
# port. Each case runs the script under `env -i` with only the variables it sets and
# compares its whole stdout, stderr, call log and the files it leaves, and its exact exit
# code. The ssh call is written out as literal text, masking only the case's temporary
# path as TREE.
#
#   bash scripts/test-install-imp-dns-token.sh
#   CASE='local mode' bash scripts/test-install-imp-dns-token.sh   # the cases whose title holds it
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-op-read.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-bash-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/require-remote-tool-stubs.sh"

it_installs_the_token_over_ssh_stdin_and_keeps_the_other_env_lines() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@example.net > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"
  printf '%s\n' IMP_FOO=bar IMP_ACME_EMAIL=old@example.net IMP_DNS_API_TOKEN=old-token IMP_OTHER=1 \
    > "$tree/host/secrets/imp-host.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" IMP_ENV_FILE="$tree/host/secrets/imp-host.env" \
    IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" bash install-imp-dns-token.sh) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << OUT
installed: token file $tree/host/secrets/dns-api-token (34 bytes, mode 400); $tree/host/secrets/imp-host.env has 1 email line, 0 token lines, mode 400
OUT
  sed "s|$tree|TREE|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << 'CALLS'
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/acme-email"]
["ssh","-o","BatchMode=yes","root@geoffcloud","bash -c $'set -euo pipefail\\nenv_file=$1\\ntoken_file=$2\\nIFS= read -r token\\nIFS= read -r email\\numask 077\\ntmp_token=$(mktemp \"$token_file.XXXXXX\")\\ntmp_env=$(mktemp \"$env_file.XXXXXX\")\\ntrap \"rm -f \\\\\"$tmp_token\\\\\" \\\\\"$tmp_env\\\\\"\" EXIT\\nprintf \"%s\" \"$token\" > \"$tmp_token\"\\n{ grep -vE \"^(IMP_DNS_API_TOKEN|IMP_ACME_EMAIL)=\" \"$env_file\" || true; printf \"IMP_ACME_EMAIL=%s\\\\n\" \"$email\"; } > \"$tmp_env\"\\nunset token email\\nchmod 0400 \"$tmp_token\" \"$tmp_env\"\\nchown 0:0 \"$tmp_token\" \"$tmp_env\" 2>/dev/null || true\\nmv -f \"$tmp_token\" \"$token_file\"\\nmv -f \"$tmp_env\" \"$env_file\"\\ntrap - EXIT\\necho \"installed: token file $token_file ($(stat -c %s \"$token_file\") bytes, mode $(stat -c %a \"$token_file\")); $env_file has $(grep -c \"^IMP_ACME_EMAIL=\" \"$env_file\") email line, $(grep -c \"^IMP_DNS_API_TOKEN=\" \"$env_file\") token lines, mode $(stat -c %a \"$env_file\")\"' _ TREE/host/secrets/imp-host.env TREE/host/secrets/dns-api-token"]
CALLS
  printf '%s' cf_test_TOKEN-0123456789abcdefghij | diff - "$tree/host/secrets/dns-api-token"
  diff - "$tree/host/secrets/imp-host.env" << 'ENV'
IMP_FOO=bar
IMP_OTHER=1
IMP_ACME_EMAIL=acme@example.net
ENV
  (cd "$tree/host/secrets" && stat -c '%a %n' -- *) > "$tree/modes"
  diff - "$tree/modes" << 'MODES'
400 dns-api-token
400 imp-host.env
MODES
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_installs_here_in_local_mode_from_the_named_references() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/staging/dns"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/vault/staging/dns/token"
  printf '%s' acme@example.net > "$tree/vault/staging/dns/email"
  printf '%s\n' IMP_FOO=bar > "$tree/host/secrets/imp-host.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    IMP_HOST=local IMP_DNS_TOKEN_REF=op://staging/dns/token IMP_ACME_EMAIL_REF=op://staging/dns/email \
    IMP_ENV_FILE="$tree/host/secrets/imp-host.env" IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" \
    bash install-imp-dns-token.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << OUT
installed: token file $tree/host/secrets/dns-api-token (34 bytes, mode 400); $tree/host/secrets/imp-host.env has 1 email line, 0 token lines, mode 400
OUT
  diff - "$tree/calls" << 'CALLS'
["op","read","--no-newline","op://staging/dns/token"]
["op","read","--no-newline","op://staging/dns/email"]
CALLS
  printf '%s' cf_test_TOKEN-0123456789abcdefghij | diff - "$tree/host/secrets/dns-api-token"
  diff - "$tree/host/secrets/imp-host.env" << 'ENV'
IMP_FOO=bar
IMP_ACME_EMAIL=acme@example.net
ENV
  (cd "$tree/host/secrets" && stat -c '%a %n' -- *) > "$tree/modes"
  diff - "$tree/modes" << 'MODES'
400 dns-api-token
400 imp-host.env
MODES
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_replaces_a_token_file_it_installed_before() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' cf_test_TOKEN-rotated-0123456789abc > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@example.net > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/host/secrets/dns-api-token"
  printf '%s\n' IMP_ACME_EMAIL=acme@example.net > "$tree/host/secrets/imp-host.env"
  chmod 0400 "$tree/host/secrets/dns-api-token" "$tree/host/secrets/imp-host.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    IMP_HOST=local IMP_ENV_FILE="$tree/host/secrets/imp-host.env" IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" \
    bash install-imp-dns-token.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << OUT
installed: token file $tree/host/secrets/dns-api-token (35 bytes, mode 400); $tree/host/secrets/imp-host.env has 1 email line, 0 token lines, mode 400
OUT
  diff - "$tree/calls" << 'CALLS'
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/acme-email"]
CALLS
  printf '%s' cf_test_TOKEN-rotated-0123456789abc | diff - "$tree/host/secrets/dns-api-token"
  diff - "$tree/host/secrets/imp-host.env" <<< IMP_ACME_EMAIL=acme@example.net
  (cd "$tree/host/secrets" && stat -c '%a %n' -- *) > "$tree/modes"
  diff - "$tree/modes" << 'MODES'
400 dns-api-token
400 imp-host.env
MODES
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_writes_an_env_file_with_only_the_email_line_when_none_is_there() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@example.net > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    IMP_HOST=local IMP_ENV_FILE="$tree/host/secrets/imp-host.env" IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" \
    bash install-imp-dns-token.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< "grep: $tree/host/secrets/imp-host.env: No such file or directory"
  diff - "$tree/out" << OUT
installed: token file $tree/host/secrets/dns-api-token (34 bytes, mode 400); $tree/host/secrets/imp-host.env has 1 email line, 0 token lines, mode 400
OUT
  diff - "$tree/calls" << 'CALLS'
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/acme-email"]
CALLS
  diff - "$tree/host/secrets/imp-host.env" <<< IMP_ACME_EMAIL=acme@example.net
  (cd "$tree/host/secrets" && stat -c '%a %n' -- *) > "$tree/modes"
  diff - "$tree/modes" << 'MODES'
400 dns-api-token
400 imp-host.env
MODES
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_stops_with_exit_1_and_changes_nothing_when_the_token_does_not_look_like_a_Cloudflare_token() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' 'not a token: has spaces' > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@example.net > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"
  printf '%s\n' IMP_FOO=bar > "$tree/host/secrets/imp-host.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" IMP_ENV_FILE="$tree/host/secrets/imp-host.env" \
    IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" bash install-imp-dns-token.sh) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the value at op://cloud/imp-dns-cloudflare/credential does not look like a Cloudflare API token; nothing changed'
  diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]'
  diff - "$tree/host/secrets/imp-host.env" <<< IMP_FOO=bar
  ls -A "$tree/host/secrets" > "$tree/files"
  diff - "$tree/files" <<< imp-host.env
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_with_exit_1_and_changes_nothing_when_the_email_does_not_look_like_an_email() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@localhost > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"
  printf '%s\n' IMP_FOO=bar > "$tree/host/secrets/imp-host.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" IMP_ENV_FILE="$tree/host/secrets/imp-host.env" \
    IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" bash install-imp-dns-token.sh) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the value at op://cloud/imp-dns-cloudflare/acme-email does not look like an email address; nothing changed'
  diff - "$tree/calls" << 'CALLS'
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/acme-email"]
CALLS
  diff - "$tree/host/secrets/imp-host.env" <<< IMP_FOO=bar
  ls -A "$tree/host/secrets" > "$tree/files"
  diff - "$tree/files" <<< imp-host.env
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_with_op_exit_1_and_changes_nothing_when_the_token_item_is_missing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' IMP_FOO=bar > "$tree/host/secrets/imp-host.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" IMP_ENV_FILE="$tree/host/secrets/imp-host.env" \
    IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" bash install-imp-dns-token.sh) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
[ERROR] 2026/10/07 12:00:00 could not read secret op://cloud/imp-dns-cloudflare/credential: could not get item cloud/imp-dns-cloudflare: "imp-dns-cloudflare" isn't an item in the "cloud" vault.
ERR
  diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]'
  diff - "$tree/host/secrets/imp-host.env" <<< IMP_FOO=bar
  ls -A "$tree/host/secrets" > "$tree/files"
  diff - "$tree/files" <<< imp-host.env
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_with_exit_1_and_leaves_both_files_when_the_host_may_not_write_the_secrets_directory() {
  local status=0
  tree="$(mktemp -d)"
  trap 'chmod -R u+w "$tree" || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@example.net > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"
  printf '%s' cf_test_TOKEN-old-0123456789abcdefg > "$tree/host/secrets/dns-api-token"
  printf '%s\n' IMP_FOO=bar > "$tree/host/secrets/imp-host.env"
  chmod 0500 "$tree/host/secrets"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    IMP_HOST=local IMP_ENV_FILE="$tree/host/secrets/imp-host.env" IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" \
    bash install-imp-dns-token.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "mktemp: failed to create file via template '$tree/host/secrets/dns-api-token.XXXXXX': Permission denied"
  diff - "$tree/calls" << 'CALLS'
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/acme-email"]
CALLS
  printf '%s' cf_test_TOKEN-old-0123456789abcdefg | diff - "$tree/host/secrets/dns-api-token"
  diff - "$tree/host/secrets/imp-host.env" <<< IMP_FOO=bar
  ls -A "$tree/host/secrets" > "$tree/files"
  diff - "$tree/files" << 'FILES'
dns-api-token
imp-host.env
FILES
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_with_ssh_exit_255_and_changes_nothing_when_the_host_refuses_the_connection() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@example.net > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"
  printf '%s\n' IMP_FOO=bar > "$tree/host/secrets/imp-host.env"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 IMP_HOST=ssh://root@127.0.0.1:1 IMP_ENV_FILE="$tree/host/secrets/imp-host.env" \
    IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" bash install-imp-dns-token.sh) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  sed "s|$tree|TREE|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << 'CALLS'
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/acme-email"]
["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","bash -c $'set -euo pipefail\\nenv_file=$1\\ntoken_file=$2\\nIFS= read -r token\\nIFS= read -r email\\numask 077\\ntmp_token=$(mktemp \"$token_file.XXXXXX\")\\ntmp_env=$(mktemp \"$env_file.XXXXXX\")\\ntrap \"rm -f \\\\\"$tmp_token\\\\\" \\\\\"$tmp_env\\\\\"\" EXIT\\nprintf \"%s\" \"$token\" > \"$tmp_token\"\\n{ grep -vE \"^(IMP_DNS_API_TOKEN|IMP_ACME_EMAIL)=\" \"$env_file\" || true; printf \"IMP_ACME_EMAIL=%s\\\\n\" \"$email\"; } > \"$tmp_env\"\\nunset token email\\nchmod 0400 \"$tmp_token\" \"$tmp_env\"\\nchown 0:0 \"$tmp_token\" \"$tmp_env\" 2>/dev/null || true\\nmv -f \"$tmp_token\" \"$token_file\"\\nmv -f \"$tmp_env\" \"$env_file\"\\ntrap - EXIT\\necho \"installed: token file $token_file ($(stat -c %s \"$token_file\") bytes, mode $(stat -c %a \"$token_file\")); $env_file has $(grep -c \"^IMP_ACME_EMAIL=\" \"$env_file\") email line, $(grep -c \"^IMP_DNS_API_TOKEN=\" \"$env_file\") token lines, mode $(stat -c %a \"$env_file\")\"' _ TREE/host/secrets/imp-host.env TREE/host/secrets/dns-api-token"]
CALLS
  diff - "$tree/host/secrets/imp-host.env" <<< IMP_FOO=bar
  ls -A "$tree/host/secrets" > "$tree/files"
  diff - "$tree/files" <<< imp-host.env
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

# Runtime every case needs: the script in <tree>, the op and ssh stand-ins with fail-closed
# stand-ins for the other remote tools in <tree>/bin, the host's PATH stand-ins in
# <tree>/host-bin, each checked so no call can reach a real remote tool, the empty call log,
# the host's secrets directory, and the HOME and TMPDIR the script runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/host-bin" "$tree/home" "$tree/tmp" "$tree/host/secrets"
  : > "$tree/calls"
  cp "$(dirname "${BASH_SOURCE[0]}")/install-imp-dns-token.sh" "$tree/"
  create_stub_op_read "$tree/bin"
  create_stub_bash_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  create_stub_remote_tools "$tree/host-bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
  require_remote_tool_stubs "$tree/host-bin"
}

run_cases
