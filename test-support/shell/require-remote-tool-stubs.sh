# shellcheck shell=bash
# require_remote_tool_stubs <bin> [<system-path>]: returns 0 only when each of ssh, scp, sftp,
# rsync and tailscale resolves, on the PATH a case runs its script with (<bin>, then
# <system-path>, which defaults to /usr/bin:/bin), to an executable inside <bin>. Otherwise
# it prints "<tool> stand-in in <bin> is not executable" for a stand-in without its x bit
# (bash versions differ on what `command -v` returns for one), or "<tool> resolves to
# <path>, not a stand-in in <bin>" ("nothing" when no directory holds the tool), to stderr
# and returns 1, so a setup_test under errexit ends the case before its script can reach a
# real remote tool. Callers leave <system-path> at its default; the guard's own tests pass
# a directory they control, so the expected text does not depend on the host. It only
# resolves each name; it runs none of them.
require_remote_tool_stubs() {
  local bin="$1" system_path="${2:-/usr/bin:/bin}" tool resolved
  for tool in ssh scp sftp rsync tailscale; do
    if [ -e "$bin/$tool" ] && [ ! -x "$bin/$tool" ]; then
      echo "$tool stand-in in $bin is not executable" >&2
      return 1
    fi
    resolved="$(PATH="$bin:$system_path" command -v "$tool" || true)"
    if [ "$resolved" != "$bin/$tool" ] || [ ! -x "$resolved" ]; then
      echo "$tool resolves to ${resolved:-nothing}, not a stand-in in $bin" >&2
      return 1
    fi
  done
}
