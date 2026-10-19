#!/usr/bin/env bash
# Hold a host switch that would stop or restart k3s, because nixie and every other pod on the
# cluster depend on it and can stay down for minutes after it restarts. switch-geoffcloud.sh runs
# it after the copy and before the activation, with what the copied system's
# `switch-to-configuration dry-activate` printed on stdin:
#
#   bash scripts/check-k3s-restart.sh [--allow-k3s-restart] < <dry-activate output>
#
# dry-activate changes nothing on the host. It lists the units the switch would stop in a
# "would stop the following units: " line and the units it would restart in a "would restart
# the following units: " line, each list joined with ", " (nixpkgs'
# switch-to-configuration-ng, main.rs). A changed unit with stopIfChanged, the NixOS default,
# sits on the stop line and the start line, one without it on the restart line, and a removed
# unit on the stop line. A unit with restartIfChanged off sits on a "would NOT stop" line, and
# a stopped unit the switch starts sits on the start line only; neither interrupts k3s.
#
# It prints nothing and exits 0 when neither list holds k3s.service. It exits 1 with the lines
# that hold it when one does, unless --allow-k3s-restart names a planned k3s window: then it
# prints those lines and exits 0.
set -euo pipefail

allow=0
case "$#:${1:-}" in
  0:) ;;
  1:--allow-k3s-restart) allow=1 ;;
  *)
    echo "usage: check-k3s-restart.sh [--allow-k3s-restart] < <dry-activate output>" >&2
    exit 2
    ;;
esac

held=()
while IFS= read -r line; do
  if [[ "$line" =~ ^would\ (stop|restart)\ the\ following\ units:\ (.*)$ ]]; then
    IFS=, read -ra units <<< "${BASH_REMATCH[2]}"
    for unit in "${units[@]}"; do
      if [ "${unit# }" = k3s.service ]; then
        held+=("$line")
        break
      fi
    done
  fi
done

if [ "${#held[@]}" = 0 ]; then
  exit 0
fi
if [ "$allow" = 1 ]; then
  echo "== k3s.service restarts in this planned k3s window (--allow-k3s-restart):"
  printf '%s\n' "${held[@]}"
  exit 0
fi
{
  echo "the switch would interrupt k3s.service, and nixie can stay down for minutes after it:"
  printf '%s\n' "${held[@]}"
  echo "switch in a planned k3s window with --allow-k3s-restart"
} >&2
exit 1
