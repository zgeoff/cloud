#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-op-read.sh: the op stand-in prints a field from the case's vault
# directory with no newline, fails a missing item with op's error and exit 1, and fails
# closed on anything else.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-op-read.sh'
  load 'create-stub-remote-tools.sh'
  load 'require-remote-tool-stubs.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# Runtime every case needs: the stand-in in <tree>/bin, with fail-closed stand-ins for every
# remote tool, checked so no call can reach a real remote tool, the empty call log, and the
# HOME and TMPDIR the stand-in runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_op_read "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

@test "it prints the field with no newline" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/dns"
  printf '%s' token-value > "$tree/vault/cloud/dns/credential"

  # to a file, so the missing newline reaches the comparison
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op read --no-newline op://cloud/dns/credential > "$tree/out" 2> "$tree/err"

  printf '%s' token-value | diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud/dns/credential"]'
}

@test "it fails a missing item with ops error and exit 1" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op read --no-newline op://cloud/dns/credential

  refute_output
  assert_stderr - << 'ERR'
[ERROR] 2026/10/07 12:00:00 could not read secret op://cloud/dns/credential: could not get item cloud/dns: "dns" isn't an item in the "cloud" vault.
ERR
  diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud/dns/credential"]'
}

@test "it fails closed with exit 97 on a field the item does not hold" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/dns"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op read --no-newline op://cloud/dns/credential

  refute_output
  assert_stderr 'unexpected: read --no-newline op://cloud/dns/credential'
  diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud/dns/credential"]'
}

@test "it fails closed with exit 97 on a read without no newline" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/dns"
  printf '%s' token-value > "$tree/vault/cloud/dns/credential"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op read op://cloud/dns/credential

  refute_output
  assert_stderr 'unexpected: read op://cloud/dns/credential'
  diff - "$tree/calls" <<< '["op","read","op://cloud/dns/credential"]'
}

@test "it fails closed with exit 97 on any other command" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item list --vault cloud

  refute_output
  assert_stderr 'unexpected: item list --vault cloud'
  diff - "$tree/calls" <<< '["op","item","list","--vault","cloud"]'
}
