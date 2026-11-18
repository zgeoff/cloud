# shellcheck shell=bash
# create_stub_op_read <bin>: writes <bin>/op, a stand-in for the 1Password CLI's
# `op read --no-newline op://<vault>/<item>/<field>`, as install-imp-dns-token.sh and
# alert-prod-apply.sh call it.
# A vault is a directory under STUB_TREE/vault/, an item a directory in it, and a field a
# file in that, holding the field's value. It logs each call's argv as a JSON line to
# STUB_TREE/calls and prints the field's value with no newline added. For an item that is
# not there it prints op's "[ERROR] <date> could not read secret …" line and exits 1, as
# print-op-error.sh records it with its sources. Any other call, including a read without
# --no-newline and a read of a field the item does not hold (whose op text is not
# modelled), ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_op_read() {
  local bin="$1"
  {
    printf '#!/usr/bin/env bash\nsource %q\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/print-op-error.sh"
    cat << 'STUB'
printf '%s\0' op "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
if [ "$#" != 3 ] || [ "$1 $2" != "read --no-newline" ] || [[ ! "$3" =~ ^op://([^/]+)/([^/]+)/([^/]+)$ ]]; then
  echo "unexpected: $*" >&2
  exit 97
fi
vault="${BASH_REMATCH[1]}" item="${BASH_REMATCH[2]}" field="${BASH_REMATCH[3]}"
if [ ! -d "$STUB_TREE/vault/$vault/$item" ]; then print_op_error unreadable-secret "$3" "$vault" "$item"; fi
if [ ! -f "$STUB_TREE/vault/$vault/$item/$field" ]; then
  echo "unexpected: $*" >&2
  exit 97
fi
cat "$STUB_TREE/vault/$vault/$item/$field"
STUB
  } > "$bin/op"
  chmod +x "$bin/op"
}
