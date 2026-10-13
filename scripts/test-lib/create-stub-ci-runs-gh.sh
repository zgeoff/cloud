# shellcheck shell=bash
# create_stub_ci_runs_gh <bin>: writes <bin>/gh, a stand-in for the GitHub CLI that
# find-ci-run.sh calls to list the CI workflow's green push runs on main. It logs each call's argv
# as a JSON line to STUB_LOG:
#
# - `api -X GET repos/{owner}/{repo}/actions/workflows/ci.yml/runs …`: prints STUB_RUNS, the
#   lines the call's --jq filter prints (one run URL per line), or nothing when STUB_RUNS is unset
#   or empty. When STUB_GH_ERROR is set, it prints that on stderr and exits STUB_GH_EXIT
#   (default 1);
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed command,
# such as an API error, and 4 when gh needs authentication.
create_stub_ci_runs_gh() {
  local bin="$1"
  cat > "$bin/gh" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' gh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
case "$*" in
  "api -X GET repos/{owner}/{repo}/actions/workflows/ci.yml/runs "*)
    if [ -n "${STUB_GH_ERROR:-}" ]; then echo "$STUB_GH_ERROR" >&2; exit "${STUB_GH_EXIT:-1}"; fi
    if [ -n "${STUB_RUNS:-}" ]; then printf '%s\n' "$STUB_RUNS"; fi
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/gh"
}
