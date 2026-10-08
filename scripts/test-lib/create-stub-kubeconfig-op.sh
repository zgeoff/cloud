# shellcheck shell=bash
# create_stub_kubeconfig_op <bin>: writes <bin>/op, a stand-in for the 1Password CLI's item
# and document commands, as connect-k3s.sh calls them. A vault is a directory under
# STUB_TREE/vault/, a document item a directory in it, and its file a file in that, named
# by --file-name. It logs each call's argv as a JSON line to STUB_TREE/calls and answers:
#
# - `item get <item> --vault <vault>`: the item's ID, title and vault, or op's "isn't an
#   item" error and exit 1;
# - `document edit <item> --vault <vault> --file-name <name> -`: replaces the item's file
#   with stdin and prints nothing, or the "isn't an item" error and exit 1;
# - `document create --vault <vault> --title <item> --file-name <name> -`: writes the item
#   from stdin and prints its JSON (uuid, createdAt, updatedAt, vaultUuid); a title the
#   vault already holds, which real op would duplicate, is not modelled and ends with 97;
# - STUB_OP_FAIL_AT (document-edit, document-create) fails that call as op does when it is
#   rate limited, writing nothing;
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# A vault that is not there fails each call with op's "isn't a vault" error. Its errors are
# op's "[ERROR] <date> <message>" lines with exit 1. The "isn't a vault" and rate-limit
# texts are create-stub-op.sh's, word for word, with its sources: the rate-limit text from
# the documentation below, the "isn't a vault" text from community reports of op 2.
#
# Checked on 2026-10-08 against 1Password's CLI documentation, not a real op (no 1Password
# account runs in a test). The documentation carries no version of its own; op 2.40.0
# (https://app-updates.agilebits.com/product_history/CLI2) was current then and is the
# version images/agent/Dockerfile pins:
#
# - https://www.1password.dev/cli/reference/management-commands/item/ : `item get
#   { <itemName> | <itemID> } --vault <vault>`;
# - https://www.1password.dev/cli/reference/management-commands/document/ : `document
#   create [{ <file> | - }]` with --vault, --title and --file-name, which "returns a JSON
#   object that contains the item's ID", and `document edit { <itemName> | <itemID> }
#   [{ <file> | - }]` with --vault and --file-name; both read the file from stdin for `-`;
# - https://www.1password.dev/service-accounts/rate-limits/ : the rate-limit text, as
#   create-stub-op.sh records it.
#
# The documentation does not settle, so they stay as they were and need a real op sample:
# the "isn't an item" text ("\"<item>\" isn't an item in the \"<vault>\" vault. Specify the
# item with its UUID, name, or domain."), taken from community reports of op 2; the
# columns `item get` prints without --format (ID, Title, Vault, Category here) and their
# padding; the fields of `document create`'s JSON beyond the ID (uuid, createdAt,
# updatedAt and vaultUuid here); that `document edit` prints nothing; and the exit codes
# and frame that create-stub-op.sh lists as unsettled. connect-k3s.sh discards the item and
# document output.
create_stub_kubeconfig_op() {
  local bin="$1"
  cat > "$bin/op" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' op "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
print_missing_item() {
  echo "[ERROR] 2026/10/07 12:00:00 \"$1\" isn't an item in the \"$2\" vault. Specify the item with its UUID, name, or domain." >&2
  exit 1
}
print_missing_vault() {
  echo "[ERROR] 2026/10/07 12:00:00 \"$1\" isn't a vault in this account. Specify the vault with its ID or name." >&2
  exit 1
}
print_rate_limit() {
  echo "[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You've reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests." >&2
  exit 1
}
case "$#:$1 $2" in
  "5:item get")
    if [ "$4" != --vault ]; then echo "unexpected: $*" >&2; exit 97; fi
    if [ ! -d "$STUB_TREE/vault/$5" ]; then print_missing_vault "$5"; fi
    if [ ! -d "$STUB_TREE/vault/$5/$3" ]; then print_missing_item "$3" "$5"; fi
    printf 'ID:          fixture-item-id\nTitle:       %s\nVault:       %s (fixture-vault-id)\nCategory:    DOCUMENT\n' "$3" "$5"
    ;;
  "8:document edit")
    if [ "$4 $6 $8" != "--vault --file-name -" ]; then echo "unexpected: $*" >&2; exit 97; fi
    content="$(cat; echo .)"
    if [ "${STUB_OP_FAIL_AT:-}" = document-edit ]; then print_rate_limit; fi
    if [ ! -d "$STUB_TREE/vault/$5" ]; then print_missing_vault "$5"; fi
    if [ ! -d "$STUB_TREE/vault/$5/$3" ]; then print_missing_item "$3" "$5"; fi
    rm -f "$STUB_TREE/vault/$5/$3"/*
    printf '%s' "${content%.}" > "$STUB_TREE/vault/$5/$3/$7"
    ;;
  "9:document create")
    if [ "$3 $5 $7 $9" != "--vault --title --file-name -" ]; then echo "unexpected: $*" >&2; exit 97; fi
    content="$(cat; echo .)"
    if [ "${STUB_OP_FAIL_AT:-}" = document-create ]; then print_rate_limit; fi
    if [ ! -d "$STUB_TREE/vault/$4" ]; then print_missing_vault "$4"; fi
    if [ -e "$STUB_TREE/vault/$4/$6" ]; then echo "unexpected: $*" >&2; exit 97; fi
    mkdir "$STUB_TREE/vault/$4/$6"
    printf '%s' "${content%.}" > "$STUB_TREE/vault/$4/$6/$8"
    echo '{"uuid":"fixture-item-id","createdAt":"2026-10-07T12:00:00Z","updatedAt":"2026-10-07T12:00:00Z","vaultUuid":"fixture-vault-id"}'
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/op"
}
