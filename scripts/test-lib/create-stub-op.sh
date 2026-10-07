# shellcheck shell=bash
# create_stub_op <bin>: writes <bin>/op, a stand-in for the 1Password CLI that
# install-atc-gateway-credentials.sh calls. It keeps its state under STUB_TREE: a vault is a
# directory under STUB_TREE/vault/, an item a file there holding its credential. It logs
# each call's argv as a JSON line to STUB_TREE/calls and records the service-account token
# it ran with (or "unset") in STUB_TREE/op-token-seen. Its JSON follows op's item and
# vault JSON, and its errors op's "[ERROR] <date> <message>" lines with exit 1:
#
# - `vault get <vault> --format json`: the vault, or op's "isn't a vault" error;
# - `item list --vault <vault> --format json`: an item per file;
# - `item create --vault <vault> - --format json`: writes the stdin item's credential;
# - `read op://<vault>/<item>/credential`: the credential and a newline, or
#   STUB_OP_READ_VALUE when set;
# - STUB_OP_FAIL_AT (item-list, item-create) fails that call as op does when it is rate
#   limited;
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
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
      echo "[ERROR] 2026/10/07 12:00:00 Too many requests. Please try again later." >&2
      exit 1
    fi
    (cd "$STUB_TREE/vault/$4" && ls -A) | jq -R --arg vault "$4" \
      '{id: "fixture-item-id", title: ., version: 1, vault: {id: "fixture-vault-id", name: $vault}, category: "API_CREDENTIAL"}' |
      jq -s .
    ;;
  "item create --vault "*" - --format json")
    item="$(cat)"
    if [ "${STUB_OP_FAIL_AT:-}" = item-create ]; then
      echo "[ERROR] 2026/10/07 12:00:00 Too many requests. Please try again later." >&2
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
