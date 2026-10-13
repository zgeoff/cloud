#!/usr/bin/env bash
# Waits for k3s's API on geoffcloud to answer, for the prod apply job once it has joined the
# tailnet: a new node reaches its peers only once the tailnet has spread its key. Any HTTP answer,
# a 401 included, shows the route is open, so curl runs without -f. It tries 30 times, each
# with a 5 s limit and a 2 s pause after a failed try, then fails (exit 1) naming the API.
#
#   bash scripts/wait-for-k3s-api.sh
set -euo pipefail

# k3s's API port, from the shared constants
port="$(jq -er .k3s.apiPort "$(dirname "${BASH_SOURCE[0]}")/../packages/topology/constants.json")"

for _ in $(seq 1 30); do
  if curl -sk -o /dev/null --max-time 5 https://geoffcloud:$port/livez; then exit 0; fi
  sleep 2
done
echo "k3s's API on geoffcloud:$port did not answer" >&2
exit 1
