# shellcheck shell=bash
# create_stub_remote_tools <bin> <log> <tool>...: writes <bin>/<tool> for each named tool
# (such as scp, sftp, rsync, tailscale), a fail-closed stand-in that appends its argv as a
# JSON line to <log> and ends with exit 97 and "unexpected: <tool> <argv>" on stderr. A
# suite whose script runs with <bin> first on PATH writes one for every remote tool its
# other stand-ins do not provide, so no call can fall through to the real tool.
create_stub_remote_tools() {
  local bin="$1" log="$2" tool
  shift 2
  for tool in "$@"; do
    {
      printf '#!/usr/bin/env bash\ntool=%q\nlog=%q\n' "$tool" "$log"
      cat << 'STUB'
printf '%s\0' "$tool" "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$log"
echo "unexpected: $tool $*" >&2
exit 97
STUB
    } > "$bin/$tool"
    chmod +x "$bin/$tool"
  done
}
