# shellcheck shell=bash
# create_stub_getent <bin>: writes <bin>/getent, a stand-in for `getent hosts <name>`, which
# would otherwise ask the machine's resolver and so reach DNS. Its records are the lines
# "<address> <name>" of STUB_TREE/hosts, read when it runs. It logs each call's argv as a
# JSON line to STUB_TREE/calls and prints a found name as glibc's getent prints a hosts
# entry ("%-15s %s"), exit 0, or prints nothing and exits 2, getent's code for a key it
# cannot find. Any other database or argument count ends with exit 97 and "unexpected:
# <argv>" on stderr.
create_stub_getent() {
  local bin="$1"
  cat > "$bin/getent" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' getent "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
if [ "$#" != 2 ] || [ "$1" != hosts ]; then echo "unexpected: $*" >&2; exit 97; fi
while read -r address name; do
  if [ "$name" = "$2" ]; then
    printf '%-15s %s\n' "$address" "$name"
    exit 0
  fi
done < <(cat "$STUB_TREE/hosts" 2> /dev/null || true)
exit 2
STUB
  chmod +x "$bin/getent"
}
