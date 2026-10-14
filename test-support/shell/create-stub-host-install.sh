# shellcheck shell=bash
# create_stub_host_install <bin>: writes <bin>/install, a stand-in for install on the host.
# It logs each call's argv as a JSON line to STUB_TREE/calls. `install -d -m 0700 -o root
# -g root <dir>`, with one absolute <dir> and nothing after it, runs the real
# `install -d -m 0700 <dir>`, without the owner, which needs root, so a case reaches
# install's real errors; any other call, including one with a second directory, ends with
# exit 97 and "unexpected: <argv>" on stderr.
create_stub_host_install() {
  local bin="$1"
  cat > "$bin/install" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' install "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
case "$*" in
  "-d -m 0700 -o root -g root /"*)
    [ "$#" = 8 ] || { echo "unexpected: $*" >&2; exit 97; }
    exec /usr/bin/install -d -m 0700 "$8"
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/install"
}
