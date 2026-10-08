#!/usr/bin/env bash
# Test for create-stub-op.sh: the 1Password stand-in keeps vaults and items as directories
# and files, answers the four op calls the credentials script makes in op's JSON and error
# shapes, records the service-account token it ran with, and fails closed on any other
# call. No op runs here (CI has no 1Password account), so its shapes are pinned as literals
# of op 2's vault and item JSON and its "[ERROR] <date> <message>" lines.
#
#   bash scripts/test-lib/test-create-stub-op.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-op.sh"

it_prints_a_vault_that_exists_and_records_the_token_it_ran_with() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture \
    op vault get cloud --format json > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '{"id":"fixture-vault-id","name":"cloud"}'
  diff /dev/null "$tree/err"
  diff - "$tree/op-token-seen" <<< ops_fixture
  diff - "$tree/calls" <<< '["op","vault","get","cloud","--format","json"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_records_unset_when_it_runs_without_a_token() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op vault get cloud --format json > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '{"id":"fixture-vault-id","name":"cloud"}'
  diff /dev/null "$tree/err"
  diff - "$tree/op-token-seen" <<< unset
  diff - "$tree/calls" <<< '["op","vault","get","cloud","--format","json"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_a_missing_vault_with_ops_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op vault get missing --format json > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '[ERROR] 2026/10/07 12:00:00 "missing" isn'"'"'t a vault in this account. Specify the vault with its ID or name.'
  diff - "$tree/calls" <<< '["op","vault","get","missing","--format","json"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_lists_each_file_in_a_vault_as_an_item() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/vault/cloud"
  printf one > "$tree/vault/cloud/first"
  printf two > "$tree/vault/cloud/second"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item list --vault cloud --format json > "$tree/out" 2> "$tree/err" || status=$?

  jq -c . "$tree/out" > "$tree/items"
  diff - "$tree/items" << 'ITEMS'
[{"id":"fixture-item-id","title":"first","version":1,"vault":{"id":"fixture-vault-id","name":"cloud"},"category":"API_CREDENTIAL"},{"id":"fixture-item-id","title":"second","version":1,"vault":{"id":"fixture-vault-id","name":"cloud"},"category":"API_CREDENTIAL"}]
ITEMS
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["op","item","list","--vault","cloud","--format","json"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_lists_an_empty_vault_as_an_empty_array() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item list --vault cloud --format json > "$tree/out" 2> "$tree/err" || status=$?

  jq -c . "$tree/out" > "$tree/items"
  diff - "$tree/items" <<< '[]'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["op","item","list","--vault","cloud","--format","json"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_the_item_list_of_a_missing_vault_with_ops_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item list --vault missing --format json > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '[ERROR] 2026/10/07 12:00:00 "missing" isn'"'"'t a vault in this account. Specify the vault with its ID or name.'
  diff - "$tree/calls" <<< '["op","item","list","--vault","missing","--format","json"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_the_item_list_as_a_rate_limited_op_when_told_to() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_OP_FAIL_AT=item-list \
    op item list --vault cloud --format json > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '[ERROR] 2026/10/07 12:00:00 Too many requests. Please try again later.'
  diff - "$tree/calls" <<< '["op","item","list","--vault","cloud","--format","json"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_writes_the_credential_of_an_item_it_creates_and_prints_the_item() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  echo '{"title":"atc-daemon-token","category":"API_CREDENTIAL","fields":[{"id":"credential","type":"CONCEALED","label":"credential","value":"fixture-bearer"}]}' |
    env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
      op item create --vault cloud - --format json > "$tree/out" 2> "$tree/err" || status=$?

  jq -c . "$tree/out" > "$tree/item"
  diff - "$tree/item" <<< '{"id":"fixture-item-id","title":"atc-daemon-token","version":1,"vault":{"id":"fixture-vault-id","name":"cloud"},"category":"API_CREDENTIAL"}'
  printf fixture-bearer > "$tree/want-credential"
  cmp "$tree/want-credential" "$tree/vault/cloud/atc-daemon-token"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["op","item","create","--vault","cloud","-","--format","json"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_an_item_create_into_a_missing_vault_with_ops_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  echo '{"title":"atc-daemon-token","category":"API_CREDENTIAL","fields":[{"id":"credential","type":"CONCEALED","label":"credential","value":"fixture-bearer"}]}' |
    env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
      op item create --vault missing - --format json > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '[ERROR] 2026/10/07 12:00:00 "missing" isn'"'"'t a vault in this account. Specify the vault with its ID or name.'
  ls -A "$tree/vault" > "$tree/vaults"
  diff /dev/null "$tree/vaults"
  diff - "$tree/calls" <<< '["op","item","create","--vault","missing","-","--format","json"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_creates_no_item_when_told_to_fail_the_create() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  echo '{"title":"atc-daemon-token","category":"API_CREDENTIAL","fields":[{"id":"credential","type":"CONCEALED","label":"credential","value":"fixture-bearer"}]}' |
    env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
      STUB_OP_FAIL_AT=item-create \
      op item create --vault cloud - --format json > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '[ERROR] 2026/10/07 12:00:00 Too many requests. Please try again later.'
  ls -A "$tree/vault/cloud" > "$tree/items"
  diff /dev/null "$tree/items"
  diff - "$tree/calls" <<< '["op","item","create","--vault","cloud","-","--format","json"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_reads_an_items_credential_with_a_trailing_newline() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/vault/cloud"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op read op://cloud/atc-daemon-token/credential > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< fixture-bearer
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["op","read","op://cloud/atc-daemon-token/credential"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_a_read_of_a_missing_item_with_ops_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op read op://cloud/atc-daemon-token/credential > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '[ERROR] 2026/10/07 12:00:00 could not read secret op://cloud/atc-daemon-token/credential: could not get item cloud/atc-daemon-token: "atc-daemon-token" isn'"'"'t an item in the "cloud" vault.'
  diff - "$tree/calls" <<< '["op","read","op://cloud/atc-daemon-token/credential"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_reads_the_named_value_instead_when_told_to() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/vault/cloud"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_OP_READ_VALUE=another-bearer \
    op read op://cloud/atc-daemon-token/credential > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< another-bearer
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["op","read","op://cloud/atc-daemon-token/credential"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item delete atc-daemon-token > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: item delete atc-daemon-token'
  diff - "$tree/calls" <<< '["op","item","delete","atc-daemon-token"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, the root of its vaults, and the
# HOME and TMPDIR each call runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/vault" "$tree/home" "$tree/tmp"
  create_stub_op "$tree/bin"
}

run_cases
