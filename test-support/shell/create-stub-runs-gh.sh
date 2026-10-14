# shellcheck shell=bash
# create_stub_runs_gh <bin>: writes <bin>/gh, a stand-in for the GitHub CLI that
# find-nixos-check-run.sh calls to list the NixOS checks workflow's green runs. It logs each
# call's argv as a JSON line to STUB_LOG:
#
# - `api -X GET repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs …`: prints
#   STUB_RUNS, the lines the call's --jq filter prints ("<head sha> <run url>" per run). With
#   STUB_RUNS unset, it prints one run for the HEAD of the repository it runs in, at
#   https://github.com/zgeoff/cloud/actions/runs/1, so a suite whose cases are not about the
#   gate passes it without naming a commit. When STUB_GH_ERROR is set, it prints that on stderr
#   and exits STUB_GH_EXIT (default 1);
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed command,
# such as an API error, and 4 when gh needs authentication.
create_stub_runs_gh() {
  local bin="$1"
  cat > "$bin/gh" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' gh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
case "$*" in
  "api -X GET repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs" | \
    "api -X GET repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs "*)
    if [ -n "${STUB_GH_ERROR:-}" ]; then echo "$STUB_GH_ERROR" >&2; exit "${STUB_GH_EXIT:-1}"; fi
    if [ -n "${STUB_RUNS+set}" ]; then
      if [ -n "$STUB_RUNS" ]; then printf '%s\n' "$STUB_RUNS"; fi
    else
      echo "$(git rev-parse HEAD) https://github.com/zgeoff/cloud/actions/runs/1"
    fi
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/gh"
}
