#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Hermetic test for install-imp-dns-token.sh: it reads imp's Cloudflare DNS token and ACME
# email from 1Password, refuses values that do not look like either, and on the host writes
# the token file and rewrites the env file, each atomically and mode 0400, keeping every
# other env line. It touches no host and no 1Password vault: op and ssh are stand-ins from
# scripts/src/test-utils/shell that log their argv as JSON lines, op reads the case's vault directory, and "the
# host" is a directory in the case's tree, where the ssh stand-in runs the script's remote
# command. Failures that real state can reach run on real state: a secrets directory the
# script may not write, an env file that is not there, and ssh refused by a dead loopback
# port. The case with the read-only directory runs the script through run_with_file_modes, so
# the mode binds a run as root too. Each case runs the script under `env -i` with only the variables it sets and
# compares its whole stdout, stderr, call log and the files it leaves, and its exact exit
# code. The ssh call is written out as literal text, masking only the case's temporary
# path as TREE.
#
#   bash scripts/run-bats.sh
#   CASE='local mode' bash scripts/run-bats.sh   # the cases whose title holds it

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-op-read.sh'
  load 'src/test-utils/shell/create-stub-bash-ssh.sh'
  load 'src/test-utils/shell/create-stub-remote-tools.sh'
  load 'src/test-utils/shell/require-remote-tool-stubs.sh'
  load 'src/test-utils/shell/run-with-file-modes.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
  chmod -R u+w "$tree" || true
}

# Runtime every case needs: the script in <tree>, the op and ssh stand-ins with fail-closed
# stand-ins for the other remote tools in <tree>/bin, the host's PATH stand-ins in
# <tree>/host-bin, each checked so no call can reach a real remote tool, the empty call log,
# the host's secrets directory, and the HOME and TMPDIR the script runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/host-bin" "$tree/home" "$tree/tmp" "$tree/host/secrets"
  : > "$tree/calls"
  cp "$BATS_TEST_DIRNAME/install-imp-dns-token.sh" "$tree/"
  create_stub_op_read "$tree/bin"
  create_stub_bash_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  create_stub_remote_tools "$tree/host-bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
  require_remote_tool_stubs "$tree/host-bin"
}

@test "it installs the token over ssh stdin and keeps the other env lines" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@example.net > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"
  printf '%s\n' IMP_FOO=bar IMP_ACME_EMAIL=old@example.net IMP_DNS_API_TOKEN=old-token IMP_OTHER=1 \
    > "$tree/host/secrets/imp-host.env"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" IMP_SECRETS_MOUNT= \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" IMP_ENV_FILE="$tree/host/secrets/imp-host.env" \
    IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" bash install-imp-dns-token.sh

  refute_stderr
  assert_output - << OUT
installed: token file $tree/host/secrets/dns-api-token (34 bytes, mode 400); $tree/host/secrets/imp-host.env has 1 email line, 0 token lines, mode 400
OUT

  sed "s|$tree|TREE|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << 'CALLS'
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/acme-email"]
["ssh","-o","BatchMode=yes","root@geoffcloud","bash -c $'set -euo pipefail\\nenv_file=$1\\ntoken_file=$2\\nif [ -n \"$3\" ] && ! mountpoint -q \"$3\"; then\\n  echo \"$3 is not a mount point; nothing changed\" >&2\\n  exit 1\\nfi\\nIFS= read -r token\\nIFS= read -r email\\numask 077\\ntmp_token=$(mktemp \"$token_file.XXXXXX\")\\ntmp_env=$(mktemp \"$env_file.XXXXXX\")\\ntrap \"rm -f \\\\\"$tmp_token\\\\\" \\\\\"$tmp_env\\\\\"\" EXIT\\nprintf \"%s\" \"$token\" > \"$tmp_token\"\\n{ grep -vE \"^(IMP_DNS_API_TOKEN|IMP_ACME_EMAIL)=\" \"$env_file\" || true; printf \"IMP_ACME_EMAIL=%s\\\\n\" \"$email\"; } > \"$tmp_env\"\\nunset token email\\nchmod 0400 \"$tmp_token\" \"$tmp_env\"\\nchown 0:0 \"$tmp_token\" \"$tmp_env\" 2>/dev/null || true\\nmv -f \"$tmp_token\" \"$token_file\"\\nmv -f \"$tmp_env\" \"$env_file\"\\ntrap - EXIT\\necho \"installed: token file $token_file ($(stat -c %s \"$token_file\") bytes, mode $(stat -c %a \"$token_file\")); $env_file has $(grep -c \"^IMP_ACME_EMAIL=\" \"$env_file\") email line, $(grep -c \"^IMP_DNS_API_TOKEN=\" \"$env_file\") token lines, mode $(stat -c %a \"$env_file\")\"' _ TREE/host/secrets/imp-host.env TREE/host/secrets/dns-api-token ''"]
CALLS
  run -0 diff <(printf '%s' cf_test_TOKEN-0123456789abcdefghij) "$tree/host/secrets/dns-api-token"
  run -0 diff - "$tree/host/secrets/imp-host.env" << 'ENV'
IMP_FOO=bar
IMP_OTHER=1
IMP_ACME_EMAIL=acme@example.net
ENV
  (cd "$tree/host/secrets" && stat -c '%a %n' -- *) > "$tree/modes"
  run -0 diff - "$tree/modes" << 'MODES'
400 dns-api-token
400 imp-host.env
MODES
}

@test "it installs here in local mode from the named references" {
  setup_test "$tree"
  mkdir -p "$tree/vault/staging/dns"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/vault/staging/dns/token"
  printf '%s' acme@example.net > "$tree/vault/staging/dns/email"
  printf '%s\n' IMP_FOO=bar > "$tree/host/secrets/imp-host.env"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" IMP_SECRETS_MOUNT= \
    IMP_HOST=local IMP_DNS_TOKEN_REF=op://staging/dns/token IMP_ACME_EMAIL_REF=op://staging/dns/email \
    IMP_ENV_FILE="$tree/host/secrets/imp-host.env" IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" \
    bash install-imp-dns-token.sh

  refute_stderr
  assert_output - << OUT
installed: token file $tree/host/secrets/dns-api-token (34 bytes, mode 400); $tree/host/secrets/imp-host.env has 1 email line, 0 token lines, mode 400
OUT

  run -0 diff - "$tree/calls" << 'CALLS'
["op","read","--no-newline","op://staging/dns/token"]
["op","read","--no-newline","op://staging/dns/email"]
CALLS
  run -0 diff <(printf '%s' cf_test_TOKEN-0123456789abcdefghij) "$tree/host/secrets/dns-api-token"
  run -0 diff - "$tree/host/secrets/imp-host.env" << 'ENV'
IMP_FOO=bar
IMP_ACME_EMAIL=acme@example.net
ENV
  (cd "$tree/host/secrets" && stat -c '%a %n' -- *) > "$tree/modes"
  run -0 diff - "$tree/modes" << 'MODES'
400 dns-api-token
400 imp-host.env
MODES
}

@test "it replaces a token file it installed before" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' cf_test_TOKEN-rotated-0123456789abc > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@example.net > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/host/secrets/dns-api-token"
  printf '%s\n' IMP_ACME_EMAIL=acme@example.net > "$tree/host/secrets/imp-host.env"
  chmod 0400 "$tree/host/secrets/dns-api-token" "$tree/host/secrets/imp-host.env"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" IMP_SECRETS_MOUNT= \
    IMP_HOST=local IMP_ENV_FILE="$tree/host/secrets/imp-host.env" IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" \
    bash install-imp-dns-token.sh

  refute_stderr
  assert_output - << OUT
installed: token file $tree/host/secrets/dns-api-token (35 bytes, mode 400); $tree/host/secrets/imp-host.env has 1 email line, 0 token lines, mode 400
OUT

  run -0 diff - "$tree/calls" << 'CALLS'
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/acme-email"]
CALLS
  run -0 diff <(printf '%s' cf_test_TOKEN-rotated-0123456789abc) "$tree/host/secrets/dns-api-token"
  run -0 diff - "$tree/host/secrets/imp-host.env" <<< IMP_ACME_EMAIL=acme@example.net
  (cd "$tree/host/secrets" && stat -c '%a %n' -- *) > "$tree/modes"
  run -0 diff - "$tree/modes" << 'MODES'
400 dns-api-token
400 imp-host.env
MODES
}

@test "it writes an env file with only the email line when none is there" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@example.net > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" IMP_SECRETS_MOUNT= \
    IMP_HOST=local IMP_ENV_FILE="$tree/host/secrets/imp-host.env" IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" \
    bash install-imp-dns-token.sh

  assert_stderr "grep: $tree/host/secrets/imp-host.env: No such file or directory"
  assert_output - << OUT
installed: token file $tree/host/secrets/dns-api-token (34 bytes, mode 400); $tree/host/secrets/imp-host.env has 1 email line, 0 token lines, mode 400
OUT

  run -0 diff - "$tree/calls" << 'CALLS'
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/acme-email"]
CALLS
  run -0 diff - "$tree/host/secrets/imp-host.env" <<< IMP_ACME_EMAIL=acme@example.net
  (cd "$tree/host/secrets" && stat -c '%a %n' -- *) > "$tree/modes"
  run -0 diff - "$tree/modes" << 'MODES'
400 dns-api-token
400 imp-host.env
MODES
}

@test "it stops with exit 1 and changes nothing when the token does not look like a Cloudflare token" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' 'not a token: has spaces' > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@example.net > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"
  printf '%s\n' IMP_FOO=bar > "$tree/host/secrets/imp-host.env"

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" IMP_SECRETS_MOUNT= \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" IMP_ENV_FILE="$tree/host/secrets/imp-host.env" \
    IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" bash install-imp-dns-token.sh

  refute_output
  assert_stderr 'the value at op://cloud/imp-dns-cloudflare/credential does not look like a Cloudflare API token; nothing changed'

  run -0 diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]'
  run -0 diff - "$tree/host/secrets/imp-host.env" <<< IMP_FOO=bar
  ls -A "$tree/host/secrets" > "$tree/files"
  run -0 diff - "$tree/files" <<< imp-host.env
}

@test "it stops with exit 1 and changes nothing when the email does not look like an email" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@localhost > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"
  printf '%s\n' IMP_FOO=bar > "$tree/host/secrets/imp-host.env"

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" IMP_SECRETS_MOUNT= \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" IMP_ENV_FILE="$tree/host/secrets/imp-host.env" \
    IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" bash install-imp-dns-token.sh

  refute_output
  assert_stderr 'the value at op://cloud/imp-dns-cloudflare/acme-email does not look like an email address; nothing changed'

  run -0 diff - "$tree/calls" << 'CALLS'
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/acme-email"]
CALLS
  run -0 diff - "$tree/host/secrets/imp-host.env" <<< IMP_FOO=bar
  ls -A "$tree/host/secrets" > "$tree/files"
  run -0 diff - "$tree/files" <<< imp-host.env
}

@test "it stops with op exit 1 and changes nothing when the token item is missing" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"
  printf '%s\n' IMP_FOO=bar > "$tree/host/secrets/imp-host.env"

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" IMP_SECRETS_MOUNT= \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" IMP_ENV_FILE="$tree/host/secrets/imp-host.env" \
    IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" bash install-imp-dns-token.sh

  refute_output
  assert_stderr - << 'ERR'
[ERROR] 2026/10/07 12:00:00 could not read secret op://cloud/imp-dns-cloudflare/credential: could not get item cloud/imp-dns-cloudflare: "imp-dns-cloudflare" isn't an item in the "cloud" vault.
ERR

  run -0 diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]'
  run -0 diff - "$tree/host/secrets/imp-host.env" <<< IMP_FOO=bar
  ls -A "$tree/host/secrets" > "$tree/files"
  run -0 diff - "$tree/files" <<< imp-host.env
}

@test "it fails with exit 1 and leaves both files when the host may not write the secrets directory" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@example.net > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"
  printf '%s' cf_test_TOKEN-old-0123456789abcdefg > "$tree/host/secrets/dns-api-token"
  printf '%s\n' IMP_FOO=bar > "$tree/host/secrets/imp-host.env"
  chmod 0500 "$tree/host/secrets"

  run -1 --separate-stderr run_with_file_modes env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" IMP_SECRETS_MOUNT= \
    IMP_HOST=local IMP_ENV_FILE="$tree/host/secrets/imp-host.env" IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" \
    bash install-imp-dns-token.sh

  refute_output
  # uutils mktemp names the file it tried, whose suffix is random, so the case masks it
  # shellcheck disable=SC2001 # a regex mask, which ${variable//search/replace} cannot express
  stderr="$(sed -E 's|(/dns-api-token\.)[A-Za-z0-9]{6}"$|\1<random>"|' <<< "$stderr")"
  case "$stderr" in
    # GNU coreutils mktemp
    "mktemp: failed to create file via template '$tree/host/secrets/dns-api-token.XXXXXX': Permission denied") ;;
    # uutils coreutils mktemp 0.10.0
    "mktemp: Permission denied (os error 13) at path \"$tree/host/secrets/dns-api-token.<random>\"") ;;
    *) fail "the install into a secrets directory the host may not write: stderr matches no supported mktemp: $stderr" ;;
  esac

  run -0 diff - "$tree/calls" << 'CALLS'
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/acme-email"]
CALLS
  run -0 diff <(printf '%s' cf_test_TOKEN-old-0123456789abcdefg) "$tree/host/secrets/dns-api-token"
  run -0 diff - "$tree/host/secrets/imp-host.env" <<< IMP_FOO=bar
  ls -A "$tree/host/secrets" > "$tree/files"
  run -0 diff - "$tree/files" << 'FILES'
dns-api-token
imp-host.env
FILES
}

@test "it refuses and writes nothing when the secrets directory is not a mount point" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@example.net > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    IMP_HOST=local IMP_SECRETS_MOUNT="$tree/host/secrets" IMP_ENV_FILE="$tree/host/secrets/imp-host.env" \
    IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" bash install-imp-dns-token.sh

  refute_output
  assert_stderr "$tree/host/secrets is not a mount point; nothing changed"

  ls -A "$tree/host/secrets" > "$tree/files"
  run -0 diff /dev/null "$tree/files"
}

@test "it fails with ssh exit 255 and changes nothing when the host refuses the connection" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/imp-dns-cloudflare"
  printf '%s' cf_test_TOKEN-0123456789abcdefghij > "$tree/vault/cloud/imp-dns-cloudflare/credential"
  printf '%s' acme@example.net > "$tree/vault/cloud/imp-dns-cloudflare/acme-email"
  printf '%s\n' IMP_FOO=bar > "$tree/host/secrets/imp-host.env"

  run -255 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" IMP_SECRETS_MOUNT= \
    STUB_SSH_PASS=1 IMP_HOST=ssh://root@127.0.0.1:1 IMP_ENV_FILE="$tree/host/secrets/imp-host.env" \
    IMP_DNS_TOKEN_FILE="$tree/host/secrets/dns-api-token" bash install-imp-dns-token.sh

  refute_output
  assert_stderr $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'

  sed "s|$tree|TREE|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << 'CALLS'
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/credential"]
["op","read","--no-newline","op://cloud/imp-dns-cloudflare/acme-email"]
["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","bash -c $'set -euo pipefail\\nenv_file=$1\\ntoken_file=$2\\nif [ -n \"$3\" ] && ! mountpoint -q \"$3\"; then\\n  echo \"$3 is not a mount point; nothing changed\" >&2\\n  exit 1\\nfi\\nIFS= read -r token\\nIFS= read -r email\\numask 077\\ntmp_token=$(mktemp \"$token_file.XXXXXX\")\\ntmp_env=$(mktemp \"$env_file.XXXXXX\")\\ntrap \"rm -f \\\\\"$tmp_token\\\\\" \\\\\"$tmp_env\\\\\"\" EXIT\\nprintf \"%s\" \"$token\" > \"$tmp_token\"\\n{ grep -vE \"^(IMP_DNS_API_TOKEN|IMP_ACME_EMAIL)=\" \"$env_file\" || true; printf \"IMP_ACME_EMAIL=%s\\\\n\" \"$email\"; } > \"$tmp_env\"\\nunset token email\\nchmod 0400 \"$tmp_token\" \"$tmp_env\"\\nchown 0:0 \"$tmp_token\" \"$tmp_env\" 2>/dev/null || true\\nmv -f \"$tmp_token\" \"$token_file\"\\nmv -f \"$tmp_env\" \"$env_file\"\\ntrap - EXIT\\necho \"installed: token file $token_file ($(stat -c %s \"$token_file\") bytes, mode $(stat -c %a \"$token_file\")); $env_file has $(grep -c \"^IMP_ACME_EMAIL=\" \"$env_file\") email line, $(grep -c \"^IMP_DNS_API_TOKEN=\" \"$env_file\") token lines, mode $(stat -c %a \"$env_file\")\"' _ TREE/host/secrets/imp-host.env TREE/host/secrets/dns-api-token ''"]
CALLS
  run -0 diff - "$tree/host/secrets/imp-host.env" <<< IMP_FOO=bar
  ls -A "$tree/host/secrets" > "$tree/files"
  run -0 diff - "$tree/files" <<< imp-host.env
}
