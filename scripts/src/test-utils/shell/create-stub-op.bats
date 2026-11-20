#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-op.sh: the 1Password stand-in keeps vaults and items as directories
# and files, answers the four op calls the credentials script makes in op's JSON and error
# shapes, records the service-account token it ran with, and fails closed on any other
# call. No op runs here (CI has no 1Password account), so its shapes are pinned as literals
# of op 2's vault and item JSON and its "[ERROR] <date> <message>" lines; create-stub-op.sh's
# header names the 1Password documentation they were checked against and what it leaves
# unsettled.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-op.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# Runtime every case needs: the stand-in in <tree>/bin, the root of its vaults, and the
# HOME and TMPDIR each call runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/vault" "$tree/home" "$tree/tmp"
  create_stub_op "$tree/bin"
}

@test "it prints a vault that exists and records the token it ran with" {
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture \
    op vault get cloud --format json

  assert_output '{"id":"fixture-vault-id","name":"cloud"}'
  refute_stderr
  diff - "$tree/op-token-seen" <<< ops_fixture
  diff - "$tree/calls" <<< '["op","vault","get","cloud","--format","json"]'
}

@test "it records unset when it runs without a token" {
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op vault get cloud --format json

  assert_output '{"id":"fixture-vault-id","name":"cloud"}'
  refute_stderr
  diff - "$tree/op-token-seen" <<< unset
  diff - "$tree/calls" <<< '["op","vault","get","cloud","--format","json"]'
}

@test "it fails a missing vault with ops error and exit 1" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op vault get missing --format json

  refute_output
  assert_stderr '[ERROR] 2026/10/07 12:00:00 "missing" isn'"'"'t a vault in this account. Specify the vault with its ID or name.'
  diff - "$tree/calls" <<< '["op","vault","get","missing","--format","json"]'
}

@test "it lists each file in a vault as an item" {
  setup_test "$tree"
  mkdir "$tree/vault/cloud"
  printf one > "$tree/vault/cloud/first"
  printf two > "$tree/vault/cloud/second"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item list --vault cloud --format json

  jq -c . <<< "$output" > "$tree/items"
  diff - "$tree/items" << 'ITEMS'
[{"id":"fixture-item-id","title":"first","version":1,"vault":{"id":"fixture-vault-id","name":"cloud"},"category":"API_CREDENTIAL"},{"id":"fixture-item-id","title":"second","version":1,"vault":{"id":"fixture-vault-id","name":"cloud"},"category":"API_CREDENTIAL"}]
ITEMS
  refute_stderr
  diff - "$tree/calls" <<< '["op","item","list","--vault","cloud","--format","json"]'
}

@test "it lists an empty vault as an empty array" {
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item list --vault cloud --format json

  jq -c . <<< "$output" > "$tree/items"
  diff - "$tree/items" <<< '[]'
  refute_stderr
  diff - "$tree/calls" <<< '["op","item","list","--vault","cloud","--format","json"]'
}

@test "it fails the item list of a missing vault with ops error and exit 1" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item list --vault missing --format json

  refute_output
  assert_stderr '[ERROR] 2026/10/07 12:00:00 "missing" isn'"'"'t a vault in this account. Specify the vault with its ID or name.'
  diff - "$tree/calls" <<< '["op","item","list","--vault","missing","--format","json"]'
}

@test "it fails the item list as a rate limited op when told to" {
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_OP_FAIL_AT=item-list \
    op item list --vault cloud --format json

  refute_output
  assert_stderr '[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You'"'"'ve reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests.'
  diff - "$tree/calls" <<< '["op","item","list","--vault","cloud","--format","json"]'
}

@test "it writes the credential of an item it creates and prints the item" {
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item create --vault cloud - --format json <<< '{"title":"atc-daemon-token","category":"API_CREDENTIAL","fields":[{"id":"credential","type":"CONCEALED","label":"credential","value":"fixture-bearer"}]}'

  jq -c . <<< "$output" > "$tree/item"
  diff - "$tree/item" <<< '{"id":"fixture-item-id","title":"atc-daemon-token","version":1,"vault":{"id":"fixture-vault-id","name":"cloud"},"category":"API_CREDENTIAL"}'
  printf fixture-bearer > "$tree/want-credential"
  cmp "$tree/want-credential" "$tree/vault/cloud/atc-daemon-token"
  refute_stderr
  diff - "$tree/calls" <<< '["op","item","create","--vault","cloud","-","--format","json"]'
}

@test "it fails an item create into a missing vault with ops error and exit 1" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item create --vault missing - --format json <<< '{"title":"atc-daemon-token","category":"API_CREDENTIAL","fields":[{"id":"credential","type":"CONCEALED","label":"credential","value":"fixture-bearer"}]}'

  refute_output
  assert_stderr '[ERROR] 2026/10/07 12:00:00 "missing" isn'"'"'t a vault in this account. Specify the vault with its ID or name.'
  ls -A "$tree/vault" > "$tree/vaults"
  diff /dev/null "$tree/vaults"
  diff - "$tree/calls" <<< '["op","item","create","--vault","missing","-","--format","json"]'
}

@test "it creates no item when told to fail the create" {
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_OP_FAIL_AT=item-create \
    op item create --vault cloud - --format json <<< '{"title":"atc-daemon-token","category":"API_CREDENTIAL","fields":[{"id":"credential","type":"CONCEALED","label":"credential","value":"fixture-bearer"}]}'

  refute_output
  assert_stderr '[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You'"'"'ve reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests.'
  ls -A "$tree/vault/cloud" > "$tree/items"
  diff /dev/null "$tree/items"
  diff - "$tree/calls" <<< '["op","item","create","--vault","cloud","-","--format","json"]'
}

@test "it reads an items credential with a trailing newline" {
  setup_test "$tree"
  mkdir "$tree/vault/cloud"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op read op://cloud/atc-daemon-token/credential

  assert_output fixture-bearer
  refute_stderr
  diff - "$tree/calls" <<< '["op","read","op://cloud/atc-daemon-token/credential"]'
}

@test "it fails a read of a missing item with ops error and exit 1" {
  setup_test "$tree"
  mkdir "$tree/vault/cloud"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op read op://cloud/atc-daemon-token/credential

  refute_output
  assert_stderr '[ERROR] 2026/10/07 12:00:00 could not read secret op://cloud/atc-daemon-token/credential: could not get item cloud/atc-daemon-token: "atc-daemon-token" isn'"'"'t an item in the "cloud" vault.'
  diff - "$tree/calls" <<< '["op","read","op://cloud/atc-daemon-token/credential"]'
}

@test "it reads the named value instead when told to" {
  setup_test "$tree"
  mkdir "$tree/vault/cloud"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_OP_READ_VALUE=another-bearer \
    op read op://cloud/atc-daemon-token/credential

  assert_output another-bearer
  refute_stderr
  diff - "$tree/calls" <<< '["op","read","op://cloud/atc-daemon-token/credential"]'
}

@test "it fails closed with exit 97 on any other call" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    op item delete atc-daemon-token

  refute_output
  assert_stderr 'unexpected: item delete atc-daemon-token'
  diff - "$tree/calls" <<< '["op","item","delete","atc-daemon-token"]'
}
