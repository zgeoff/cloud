# shellcheck shell=bash
# create_stub_getent <bin>: writes <bin>/getent, a stand-in for `getent hosts <name>`, which
# would otherwise ask the machine's resolver and so reach DNS. Its records are the lines
# "<address> <name>" of STUB_TREE/hosts, read when it runs. It logs each call's argv as a
# JSON line to STUB_TREE/calls and prints a found name as glibc's getent prints a hosts
# entry ("%-15s %s"), exit 0, or prints nothing and exits 2, getent's code for a key it
# cannot find. Any other database or argument count ends with exit 97 and "unexpected:
# <argv>" on stderr.
#
# Checked on 2026-10-08 against glibc's source and a real getent. nss/getent.c at glibc-2.39
# (CI's ubuntu-24.04) prints each address of a found host as printf("%-15s %s", address,
# name), then " <alias>" for each alias and a newline, and exits 2 when a key is not found.
# glibc 2.44's `getent -s files hosts localhost` printed "127.0.0.1" padded to 15 columns,
# a space and "localhost", exit 0. Left open, since no record here needs them: a name with
# aliases or several addresses, which the real getent prints in full, one line per address;
# and a name with an IPv6 address, which it looks up first.
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
