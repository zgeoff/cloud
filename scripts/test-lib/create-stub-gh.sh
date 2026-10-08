# shellcheck shell=bash
# create_stub_gh <bin>: writes <bin>/gh, a stand-in for the GitHub CLI that
# fetch-atc-release.sh calls. It logs each call's argv as a JSON line to STUB_TREE/calls,
# and the opt-out variables it ran with as the line
# "GH_TELEMETRY=<v> DO_NOT_TRACK=<v> GH_NO_UPDATE_NOTIFIER=<v>" ("unset" for a missing one)
# to STUB_TREE/gh-env, so a test reads what a caller passed gh without gh reaching any
# host. `gh release download …` answers as the real gh does for a release the repository
# lacks: "release not found" on stderr and exit 1, the answer
# test-start-stub-github-api.sh pins against the real gh. Any other call ends with exit 97
# and "unexpected: <argv>" on stderr.
create_stub_gh() {
  local bin="$1"
  cat > "$bin/gh" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' gh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
printf 'GH_TELEMETRY=%s DO_NOT_TRACK=%s GH_NO_UPDATE_NOTIFIER=%s\n' "${GH_TELEMETRY-unset}" \
  "${DO_NOT_TRACK-unset}" "${GH_NO_UPDATE_NOTIFIER-unset}" >> "$STUB_TREE/gh-env"
case "$*" in
  "release download "*) echo "release not found" >&2; exit 1 ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/gh"
}
