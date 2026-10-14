# shellcheck shell=bash
# create_stub_check_agent_image <file>: writes <file>, a stand-in for scripts/check-agent-image.sh
# that a test commits into a case repository, so build-agent-image.sh runs it from the commit it
# builds. It logs its argv as a JSON line to STUB_TREE/calls, beside the imp stand-in's calls, so
# a test sees the order of both. It prints "== 0 failed" and exits 0, as the real check does when
# every item passes, or, when STUB_CHECK_FAILURES is set, prints "== <n> failed" and exits 1, as
# the real check does on any failure.
create_stub_check_agent_image() {
  local file="$1"
  cat > "$file" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' check-agent-image.sh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
echo "== ${STUB_CHECK_FAILURES:-0} failed"
[ -z "${STUB_CHECK_FAILURES:-}" ]
STUB
}
