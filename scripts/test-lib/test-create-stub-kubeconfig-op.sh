#!/usr/bin/env bash
# Test for create-stub-kubeconfig-op.sh: the op stand-in finds a document item, creates one
# from stdin, replaces one's file from stdin, answers a missing item or vault and a rate
# limit with op's errors and exit 1, and fails closed on anything else.
#
#   bash scripts/test-lib/test-create-stub-kubeconfig-op.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-kubeconfig-op.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_prints_an_item_it_holds() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/kc"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item get kc --vault cloud > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
ID:          fixture-item-id
Title:       kc
Vault:       cloud (fixture-vault-id)
Category:    DOCUMENT
OUT
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["op","item","get","kc","--vault","cloud"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_a_missing_item_with_ops_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item get kc --vault cloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
[ERROR] 2026/10/07 12:00:00 "kc" isn't an item in the "cloud" vault. Specify the item with its UUID, name, or domain.
ERR
  diff - "$tree/calls" <<< '["op","item","get","kc","--vault","cloud"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_a_create_in_a_missing_vault_with_ops_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  printf 'doc\n' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op document create --vault cloud --title kc --file-name kc.yaml - > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
[ERROR] 2026/10/07 12:00:00 "cloud" isn't a vault in this account. Specify the vault with its ID or name.
ERR
  diff - "$tree/calls" <<< '["op","document","create","--vault","cloud","--title","kc","--file-name","kc.yaml","-"]'
  ls -A "$tree/vault" > "$tree/vaults"
  diff /dev/null "$tree/vaults"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_an_item_get_in_a_missing_vault_with_ops_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item get kc --vault cloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
[ERROR] 2026/10/07 12:00:00 "cloud" isn't a vault in this account. Specify the vault with its ID or name.
ERR
  diff - "$tree/calls" <<< '["op","item","get","kc","--vault","cloud"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_an_edit_in_a_missing_vault_with_ops_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  printf 'new\n' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op document edit kc --vault cloud --file-name kc.yaml - > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
[ERROR] 2026/10/07 12:00:00 "cloud" isn't a vault in this account. Specify the vault with its ID or name.
ERR
  ls -A "$tree/vault" > "$tree/vaults"
  diff /dev/null "$tree/vaults"
  diff - "$tree/calls" <<< '["op","document","edit","kc","--vault","cloud","--file-name","kc.yaml","-"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_creates_a_document_from_stdin_and_prints_its_JSON() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"

  printf 'line one\nline two\n' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op document create --vault cloud --title kc --file-name kc.yaml - > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '{"uuid":"fixture-item-id","createdAt":"2026-10-07T12:00:00Z","updatedAt":"2026-10-07T12:00:00Z","vaultUuid":"fixture-vault-id"}'
  diff /dev/null "$tree/err"
  printf 'line one\nline two\n' | diff - "$tree/vault/cloud/kc/kc.yaml"
  diff - "$tree/calls" <<< '["op","document","create","--vault","cloud","--title","kc","--file-name","kc.yaml","-"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_replaces_a_documents_file_from_stdin() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/kc"
  printf 'old\n' > "$tree/vault/cloud/kc/old.yaml"

  printf 'new\n' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op document edit kc --vault cloud --file-name kc.yaml - > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  ls -A "$tree/vault/cloud/kc" > "$tree/files"
  diff - "$tree/files" <<< kc.yaml
  diff - "$tree/vault/cloud/kc/kc.yaml" <<< new
  diff - "$tree/calls" <<< '["op","document","edit","kc","--vault","cloud","--file-name","kc.yaml","-"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_an_edit_of_a_missing_item_with_ops_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"

  printf 'new\n' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op document edit kc --vault cloud --file-name kc.yaml - > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
[ERROR] 2026/10/07 12:00:00 "kc" isn't an item in the "cloud" vault. Specify the item with its UUID, name, or domain.
ERR
  ls -A "$tree/vault/cloud" > "$tree/items"
  diff /dev/null "$tree/items"
  diff - "$tree/calls" <<< '["op","document","edit","kc","--vault","cloud","--file-name","kc.yaml","-"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_a_rate_limited_edit_with_ops_error_and_writes_nothing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/kc"
  printf 'old\n' > "$tree/vault/cloud/kc/kc.yaml"

  printf 'new\n' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_OP_FAIL_AT=document-edit op document edit kc --vault cloud --file-name kc.yaml - \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You've reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests."
  diff - "$tree/vault/cloud/kc/kc.yaml" <<< old
  diff - "$tree/calls" <<< '["op","document","edit","kc","--vault","cloud","--file-name","kc.yaml","-"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_a_rate_limited_create_with_ops_error_and_writes_nothing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud"

  printf 'new\n' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_OP_FAIL_AT=document-create op document create --vault cloud --title kc --file-name kc.yaml - \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You've reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests."
  ls -A "$tree/vault/cloud" > "$tree/items"
  diff /dev/null "$tree/items"
  diff - "$tree/calls" <<< '["op","document","create","--vault","cloud","--title","kc","--file-name","kc.yaml","-"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_creating_a_title_the_vault_holds() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/kc"
  printf 'old\n' > "$tree/vault/cloud/kc/kc.yaml"

  printf 'new\n' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op document create --vault cloud --title kc --file-name kc.yaml - > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: document create --vault cloud --title kc --file-name kc.yaml -'
  diff - "$tree/vault/cloud/kc/kc.yaml" <<< old
  diff - "$tree/calls" <<< '["op","document","create","--vault","cloud","--title","kc","--file-name","kc.yaml","-"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_any_other_command() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud/kc"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item delete kc --vault cloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: item delete kc --vault cloud'
  diff - "$tree/calls" <<< '["op","item","delete","kc","--vault","cloud"]'
  [ -d "$tree/vault/cloud/kc" ] || { echo "the item is gone" >&2; exit 1; }
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
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

run_cases
