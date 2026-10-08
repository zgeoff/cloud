# shellcheck shell=bash
# require_remote_tool_stubs <bin>: returns 0 only when each of ssh, scp, sftp, rsync and
# tailscale resolves, on the PATH a case runs its script with (<bin>, then /usr/bin and
# /bin), to an executable inside <bin>. Otherwise it prints "<tool> stand-in in <bin> is not
# executable" for a stand-in without its x bit (bash versions differ on what `command -v`
# returns for one), or "<tool> resolves to <path>, not a stand-in in <bin>", to stderr and
# returns 1, so a setup_test under
# errexit ends the case before its script can reach a real remote tool. It only resolves
# each name; it runs none of them.
require_remote_tool_stubs() {
  local bin="$1" tool resolved
  for tool in ssh scp sftp rsync tailscale; do
    if [ -e "$bin/$tool" ] && [ ! -x "$bin/$tool" ]; then
      echo "$tool stand-in in $bin is not executable" >&2
      return 1
    fi
    resolved="$(PATH="$bin:/usr/bin:/bin" command -v "$tool" || true)"
    if [ "$resolved" != "$bin/$tool" ] || [ ! -x "$resolved" ]; then
      echo "$tool resolves to ${resolved:-nothing}, not a stand-in in $bin" >&2
      return 1
    fi
  done
}
