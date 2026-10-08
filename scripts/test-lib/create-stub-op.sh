# shellcheck shell=bash
# create_stub_op <bin>: writes <bin>/op, a stand-in for the 1Password CLI that
# install-atc-gateway-credentials.sh calls. It keeps its state under STUB_TREE: a vault is a
# directory under STUB_TREE/vault/, an item a file there holding its credential. It logs
# each call's argv as a JSON line to STUB_TREE/calls and records the service-account token
# it ran with (or "unset") in STUB_TREE/op-token-seen. Its JSON follows op's item and
# vault JSON, and its errors op's "[ERROR] <date> <message>" lines with exit 1:
#
# - `vault get <vault> --format json`: the vault, or op's "isn't a vault" error;
# - `item list --vault <vault> --format json`: an item per file, or the "isn't a vault" error;
# - `item create --vault <vault> - --format json`: writes the stdin item's credential, or
#   the "isn't a vault" error with nothing written;
# - `read op://<vault>/<item>/credential`: the credential and a newline, or
#   STUB_OP_READ_VALUE when set, or op's "could not read secret" error for a missing item;
# - STUB_OP_FAIL_AT (item-list, item-create) fails that call as op does when it is rate
#   limited;
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# Checked on 2026-10-08 against 1Password's CLI documentation, which carries no version of
# its own; op 2.40.0 (2026-10-01, https://app-updates.agilebits.com/product_history/CLI2) was
# current then and is the version images/agent/Dockerfile pins. developer.1password.com
# redirects each page to www.1password.dev:
#
# - https://www.1password.dev/cli/reference/management-commands/vault/ : `vault get <name>`;
# - https://www.1password.dev/cli/reference/management-commands/item/ : `item list --vault`,
#   `item create --vault <vault> -` reading the item JSON on stdin;
# - https://www.1password.dev/cli/item-template-json/ : the item JSON (id, title, version,
#   vault, category, fields with id, type, label and value);
# - https://www.1password.dev/cli/reference/commands/read/ : `read` prints a newline after the
#   secret unless -n is given;
# - https://www.1password.dev/service-accounts/rate-limits/ : the rate-limit error text,
#   "[ERROR] (429) Too Many Requests: You've reached ... Please retry in 59 minutes or try
#   other requests.", which the stand-in prints for both STUB_OP_FAIL_AT calls.
#
# The documentation does not settle, so they stay as they were and need a real op sample:
# op's exit codes (the stand-in uses 1 for every error, as 1Password community answers
# describe); the "[ERROR] <date> <time>" frame, which the rate-limit example prints without
# a timestamp and after "Error: "; the "isn't a vault" and "could not read secret" texts,
# taken from community reports of op 2; the retry time in the rate-limit text; the fields
# of `vault get` (only id and name here); the fields of an `item list` element and of the
# item `item create` prints (the template example shows vault with id alone, created_at,
# updated_at and last_edited_by, which the stand-in leaves out, and a vault name it adds);
# the API_CREDENTIAL spelling, which the documentation shows only as "API Credential"; and
# the credential field's id, "credential", which the script writes and reads.
create_stub_op() {
  local bin="$1"
  cat > "$bin/op" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' op "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
printf '%s\n' "${OP_SERVICE_ACCOUNT_TOKEN-unset}" > "$STUB_TREE/op-token-seen"
case "$*" in
  "vault get "*" --format json")
    if [ -d "$STUB_TREE/vault/$3" ]; then
      jq -cn --arg name "$3" '{id: "fixture-vault-id", name: $name}'
    else
      echo "[ERROR] 2026/10/07 12:00:00 \"$3\" isn't a vault in this account. Specify the vault with its ID or name." >&2
      exit 1
    fi
    ;;
  "item list --vault "*" --format json")
    if [ "${STUB_OP_FAIL_AT:-}" = item-list ]; then
      echo "[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You've reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests." >&2
      exit 1
    fi
    if [ ! -d "$STUB_TREE/vault/$4" ]; then
      echo "[ERROR] 2026/10/07 12:00:00 \"$4\" isn't a vault in this account. Specify the vault with its ID or name." >&2
      exit 1
    fi
    (cd "$STUB_TREE/vault/$4" && ls -A) | jq -R --arg vault "$4" \
      '{id: "fixture-item-id", title: ., version: 1, vault: {id: "fixture-vault-id", name: $vault}, category: "API_CREDENTIAL"}' |
      jq -s .
    ;;
  "item create --vault "*" - --format json")
    item="$(cat)"
    if [ "${STUB_OP_FAIL_AT:-}" = item-create ]; then
      echo "[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You've reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests." >&2
      exit 1
    fi
    if [ ! -d "$STUB_TREE/vault/$4" ]; then
      echo "[ERROR] 2026/10/07 12:00:00 \"$4\" isn't a vault in this account. Specify the vault with its ID or name." >&2
      exit 1
    fi
    title="$(jq -r .title <<< "$item")"
    jq -j '.fields[] | select(.id == "credential") | .value' <<< "$item" > "$STUB_TREE/vault/$4/$title"
    jq -n --arg title "$title" --arg vault "$4" \
      '{id: "fixture-item-id", title: $title, version: 1, vault: {id: "fixture-vault-id", name: $vault}, category: "API_CREDENTIAL"}'
    ;;
  "read op://"*"/credential")
    ref="${2#op://}"
    if [ -n "${STUB_OP_READ_VALUE:-}" ]; then
      printf '%s\n' "$STUB_OP_READ_VALUE"
    elif [ ! -f "$STUB_TREE/vault/${ref%/credential}" ]; then
      vault="${ref%%/*}" item="${ref#*/}" item="${item%/credential}"
      echo "[ERROR] 2026/10/07 12:00:00 could not read secret $2: could not get item $vault/$item: \"$item\" isn't an item in the \"$vault\" vault." >&2
      exit 1
    else
      cat "$STUB_TREE/vault/${ref%/credential}"
      echo
    fi
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/op"
}
