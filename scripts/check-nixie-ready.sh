#!/usr/bin/env bash
# Check that nixie on the host reports every part of /health/ready ready. switch-geoffcloud.sh runs
# it last, so a switch that leaves nixie unable to start fails, as a switch to an impd that nixie's
# imp client refuses would, with every rollout check before it passed:
#
#   bash scripts/check-nixie-ready.sh <host>
#
# It asks nixie-0's own server, through kubectl exec over ssh, as docs/runbooks/nixie.md does by
# hand; 8080 is nixieAPIPort (infra/cluster/build-nixie-spec.ts). nixie answers 200 with every part
# ready and 503 otherwise, with each part's report in the body either way. nixie retries its start
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
fetch='console.log(await (await fetch("http://127.0.0.1:8080/health/ready")).text())'

# read_report: prints nixie's report body, or fails with the output of a try that got none. A try
# that hangs, such as a stalled ssh or exec stream, ends after 20 s, or 25 s for one that ignores
# TERM, so the 30 tries stay bounded.
read_report() {
  local status=0
  timeout -k 5 20 ssh -o BatchMode=yes "$host" "k3s kubectl -n nixie exec nixie-0 -c nixie -- bun -e '$fetch'" 2>&1 ||
    status=$?
  # 124 when the TERM at 20 s ends the try, 137 when the KILL 5 s later must
  if [ "$status" = 124 ] || [ "$status" = 137 ]; then echo "the try took longer than 20 s"; fi
  return "$status"
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
    problem="no report from nixie-0: $(tail -n 1 <<< "$report")"
  fi
  if [ "$try" -lt "$tries" ]; then sleep 10; fi
done
echo "nixie is not ready after $tries tries: $problem" >&2
exit 1
