# shellcheck shell=bash
# create_stub_timeout <bin>: writes <bin>/timeout, a stand-in for coreutils' timeout that lets a
# case end a command as an expired limit does without waiting for it. It logs each call's argv as
# a JSON line to STUB_TIMEOUT_LOG, when that is set, so the suites that log their other stand-ins
# to STUB_LOG keep their call logs. With STUB_TIMEOUT_EXPIRE set, it runs nothing and exits with
# that code: 124, which coreutils' timeout gives when its TERM ends the command, or 137, which it
# gives when the KILL of -k must end it (`timeout --help`, coreutils 9.4, read 2026-10-16);
# otherwise it runs the command after the duration and exits with its code.
# It takes only `timeout [-k <duration>] <duration> <command…>`, and ends any other call with exit 97.
create_stub_timeout() {
  local bin="$1"
  cat > "$bin/timeout" << 'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_TIMEOUT_LOG:-}" ]; then
  printf '%s\0' timeout "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TIMEOUT_LOG"
fi
args=("$@")
if [ "${1:-}" = -k ] && [[ "${2:-}" =~ ^[0-9]+$ ]]; then shift 2; fi
if [ "$#" -lt 2 ] || [[ ! "$1" =~ ^[0-9]+$ ]]; then echo "unexpected: ${args[*]}" >&2; exit 97; fi
if [ -n "${STUB_TIMEOUT_EXPIRE:-}" ]; then exit "$STUB_TIMEOUT_EXPIRE"; fi
shift
exec "$@"
STUB
  chmod +x "$bin/timeout"
}
