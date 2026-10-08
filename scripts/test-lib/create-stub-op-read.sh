# shellcheck shell=bash
# create_stub_op_read <bin>: writes <bin>/op, a stand-in for the 1Password CLI's
# `op read --no-newline op://<vault>/<item>/<field>`, as install-imp-dns-token.sh calls it.
# A vault is a directory under STUB_TREE/vault/, an item a directory in it, and a field a
# file in that, holding the field's value. It logs each call's argv as a JSON line to
# STUB_TREE/calls and prints the field's value with no newline added. For an item that is
# not there it prints op's "[ERROR] <date> could not read secret …" line and exits 1, with
# the text create-stub-op.sh uses for the same error. Any other call, including a read
# without --no-newline and a read of a field the item does not hold (whose op text is not
# modelled), ends with exit 97 and "unexpected: <argv>" on stderr.
#
# Not checked against a real op (no 1Password account runs in a test): the missing-item
# text follows the text 1Password community reports quote for op 2, as create-stub-op.sh
# records.
create_stub_op_read() {
  local bin="$1"
  cat > "$bin/op" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' op "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
if [ "$#" != 3 ] || [ "$1 $2" != "read --no-newline" ] || [[ ! "$3" =~ ^op://([^/]+)/([^/]+)/([^/]+)$ ]]; then
  echo "unexpected: $*" >&2
  exit 97
fi
vault="${BASH_REMATCH[1]}" item="${BASH_REMATCH[2]}" field="${BASH_REMATCH[3]}"
if [ ! -d "$STUB_TREE/vault/$vault/$item" ]; then
  echo "[ERROR] 2026/10/07 12:00:00 could not read secret $3: could not get item $vault/$item: \"$item\" isn't an item in the \"$vault\" vault." >&2
  exit 1
fi
if [ ! -f "$STUB_TREE/vault/$vault/$item/$field" ]; then
  echo "unexpected: $*" >&2
  exit 97
fi
cat "$STUB_TREE/vault/$vault/$item/$field"
STUB
  chmod +x "$bin/op"
}
