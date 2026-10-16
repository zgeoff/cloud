#!/usr/bin/env bash
# Check that nixie on the host reports every part of /health/ready ready. switch-geoffcloud.sh runs
# it last, so a switch that leaves nixie unable to start fails, as a switch to an impd that nixie's
# imp client refuses would, with every rollout check before it passed:
#
#   bash scripts/check-nixie-ready.sh <host>
#
# It runs nixie's documented `nixie health` command in nixie-0 through kubectl exec over ssh, as
# docs/runbooks/nixie.md does by hand. The command prints the server's readiness report either way,
# with each part's report, and exits 0 only when every part is ready. nixie retries its start
# and impd restarts with the switch, so it tries 30 times, each try ended after 20 s, with a 10 s
# pause after each try that is not ready, then fails (exit 1) and names each part that is not
# ready with nixie's reason, or the last error when no report came back. It prints the ready parts
# when it passes.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: check-nixie-ready.sh <host>" >&2
  exit 2
fi
host="$1"
tries=30
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

# read_report: prints what nixie health printed, its report when one came back, and leaves the
# try's errors in $err. A try that hangs, such as a stalled ssh or exec stream, ends after 20 s, or
# 25 s for one that ignores TERM, so the 30 tries stay bounded, and it fails, whatever it printed
# first. nixie health exits 1 when a part is not ready, so past a hang the report decides, not the
# exit code.
read_report() {
  local status=0
  timeout -k 5 20 ssh -o BatchMode=yes "$host" "k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health" 2> "$err" ||
    status=$?
  # 124 when the TERM at 20 s ends the try, 137 when the KILL 5 s later must
  if [ "$status" = 124 ] || [ "$status" = 137 ]; then
    echo "the try took longer than 20 s" >> "$err"
    return 1
  fi
}

problem=""
for try in $(seq 1 "$tries"); do
  if report="$(read_report)" && jq -e '.parts | type == "object"' <<< "$report" > /dev/null 2>&1; then
    if jq -e '.status == "ready" and ([.parts[] | .isReady == true] | all)' <<< "$report" > /dev/null; then
      echo "== nixie ready: $(jq -r '.parts | keys_unsorted | join(", ")' <<< "$report")"
      exit 0
    fi
    problem="$(jq -r '[.parts | to_entries[] | select(.value.isReady != true)
      | "\(.key): \(.value.reason // "not ready")"] | join("; ")' <<< "$report")"
    if [ -z "$problem" ]; then problem="status $(jq -c .status <<< "$report")"; fi
  else
    detail="$(tail -n 1 "$err")"
    if [ -z "$detail" ]; then detail="$(tail -n 1 <<< "$report")"; fi
    problem="no report from nixie-0: $detail"
  fi
  if [ "$try" -lt "$tries" ]; then sleep 10; fi
done
echo "nixie is not ready after $tries tries: $problem" >&2
exit 1
