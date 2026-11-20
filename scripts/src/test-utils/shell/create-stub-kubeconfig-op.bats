#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-kubeconfig-op.sh: the op stand-in finds a document item, creates one
# from stdin, replaces one's file from stdin, answers a missing item or vault and a rate
# limit with op's errors and exit 1, and fails closed on anything else.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-kubeconfig-op.sh'
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
# remote tool, checked so no call can reach a real remote tool, the empty call log, the
# vaults' directory, and the HOME and TMPDIR the stand-in runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/vault"
  : > "$tree/calls"
  create_stub_kubeconfig_op "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

@test "it prints an item it holds" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/kc"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item get kc --vault cloud

  assert_output - << 'OUT'
ID:          fixture-item-id
Title:       kc
Vault:       cloud (fixture-vault-id)
Category:    DOCUMENT
OUT
  refute_stderr
  diff - "$tree/calls" <<< '["op","item","get","kc","--vault","cloud"]'
}

@test "it fails a missing item with ops error and exit 1" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item get kc --vault cloud

  refute_output
  assert_stderr - << 'ERR'
[ERROR] 2026/10/07 12:00:00 "kc" isn't an item in the "cloud" vault. Specify the item with its UUID, name, or domain.
ERR
  diff - "$tree/calls" <<< '["op","item","get","kc","--vault","cloud"]'
}

@test "it fails a create in a missing vault with ops error and exit 1" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op document create --vault cloud --title kc --file-name kc.yaml - <<< 'doc'

  refute_output
  assert_stderr - << 'ERR'
[ERROR] 2026/10/07 12:00:00 "cloud" isn't a vault in this account. Specify the vault with its ID or name.
ERR
  diff - "$tree/calls" <<< '["op","document","create","--vault","cloud","--title","kc","--file-name","kc.yaml","-"]'
  ls -A "$tree/vault" > "$tree/vaults"
  diff /dev/null "$tree/vaults"
}

@test "it fails an item get in a missing vault with ops error and exit 1" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item get kc --vault cloud

  refute_output
  assert_stderr - << 'ERR'
[ERROR] 2026/10/07 12:00:00 "cloud" isn't a vault in this account. Specify the vault with its ID or name.
ERR
  diff - "$tree/calls" <<< '["op","item","get","kc","--vault","cloud"]'
}

@test "it fails an edit in a missing vault with ops error and exit 1" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op document edit kc --vault cloud --file-name kc.yaml - <<< 'new'

  refute_output
  assert_stderr - << 'ERR'
[ERROR] 2026/10/07 12:00:00 "cloud" isn't a vault in this account. Specify the vault with its ID or name.
ERR
  ls -A "$tree/vault" > "$tree/vaults"
  diff /dev/null "$tree/vaults"
  diff - "$tree/calls" <<< '["op","document","edit","kc","--vault","cloud","--file-name","kc.yaml","-"]'
}

@test "it creates a document from stdin and prints its JSON" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op document create --vault cloud --title kc --file-name kc.yaml - <<< $'line one\nline two'

  assert_output '{"uuid":"fixture-item-id","createdAt":"2026-10-07T12:00:00Z","updatedAt":"2026-10-07T12:00:00Z","vaultUuid":"fixture-vault-id"}'
  refute_stderr
  printf 'line one\nline two\n' | diff - "$tree/vault/cloud/kc/kc.yaml"
  diff - "$tree/calls" <<< '["op","document","create","--vault","cloud","--title","kc","--file-name","kc.yaml","-"]'
}

@test "it replaces a documents file from stdin" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/kc"
  printf 'old\n' > "$tree/vault/cloud/kc/old.yaml"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op document edit kc --vault cloud --file-name kc.yaml - <<< 'new'

  refute_output
  refute_stderr
  ls -A "$tree/vault/cloud/kc" > "$tree/files"
  diff - "$tree/files" <<< kc.yaml
  diff - "$tree/vault/cloud/kc/kc.yaml" <<< new
  diff - "$tree/calls" <<< '["op","document","edit","kc","--vault","cloud","--file-name","kc.yaml","-"]'
}

@test "it fails an edit of a missing item with ops error and exit 1" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op document edit kc --vault cloud --file-name kc.yaml - <<< 'new'

  refute_output
  assert_stderr - << 'ERR'
[ERROR] 2026/10/07 12:00:00 "kc" isn't an item in the "cloud" vault. Specify the item with its UUID, name, or domain.
ERR
  ls -A "$tree/vault/cloud" > "$tree/items"
  diff /dev/null "$tree/items"
  diff - "$tree/calls" <<< '["op","document","edit","kc","--vault","cloud","--file-name","kc.yaml","-"]'
}

@test "it fails a rate limited edit with ops error and writes nothing" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/kc"
  printf 'old\n' > "$tree/vault/cloud/kc/kc.yaml"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_OP_FAIL_AT=document-edit op document edit kc --vault cloud --file-name kc.yaml - <<< 'new'

  refute_output
  assert_stderr "[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You've reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests."
  diff - "$tree/vault/cloud/kc/kc.yaml" <<< old
  diff - "$tree/calls" <<< '["op","document","edit","kc","--vault","cloud","--file-name","kc.yaml","-"]'
}

@test "it fails a rate limited create with ops error and writes nothing" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_OP_FAIL_AT=document-create op document create --vault cloud --title kc --file-name kc.yaml - <<< 'new'

  refute_output
  assert_stderr "[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You've reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests."
  ls -A "$tree/vault/cloud" > "$tree/items"
  diff /dev/null "$tree/items"
  diff - "$tree/calls" <<< '["op","document","create","--vault","cloud","--title","kc","--file-name","kc.yaml","-"]'
}

@test "it fails closed with exit 97 on creating a title the vault holds" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/kc"
  printf 'old\n' > "$tree/vault/cloud/kc/kc.yaml"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op document create --vault cloud --title kc --file-name kc.yaml - <<< 'new'

  refute_output
  assert_stderr 'unexpected: document create --vault cloud --title kc --file-name kc.yaml -'
  diff - "$tree/vault/cloud/kc/kc.yaml" <<< old
  diff - "$tree/calls" <<< '["op","document","create","--vault","cloud","--title","kc","--file-name","kc.yaml","-"]'
}

@test "it fails closed with exit 97 on any other command" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/kc"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item delete kc --vault cloud

  refute_output
  assert_stderr 'unexpected: item delete kc --vault cloud'
  diff - "$tree/calls" <<< '["op","item","delete","kc","--vault","cloud"]'
  [ -d "$tree/vault/cloud/kc" ]
}
