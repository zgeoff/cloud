#!/usr/bin/env bash
# Takes an Onidel snapshot of geoffcloud's system disk (vda) before a risky host change,
# then lists the snapshots (#9). vdb, imp's pool, is not in it: imp's restic backups
# cover the imps. Run through op so the API key never reaches the terminal:
#   op run --env-file=.env -- bash scripts/snapshot-geoffcloud.sh pre-<change>
# Prints names, dates and status only; never the VM object, which holds the root password.
set -euo pipefail

name="${1:?usage: snapshot-geoffcloud.sh <name>, such as pre-imp-0.26}"
vm="0f289413-258f-4115-ac81-252000998fe0"
api="https://api.cloud.onidel.com"
auth="Authorization: Bearer ${ONIDEL_API_KEY:?run through op run --env-file=.env}"

curl -fsS -X POST -H "$auth" -H 'content-type: application/json' \
  --data "$(jq -n --arg n "$name" --arg d "$(date -u +%Y-%m-%dT%H:%MZ)" '{name: $n, desc: $d}')" \
  "$api/vm/$vm/snapshot" > /dev/null
echo "requested snapshot $name; it shows as available once Onidel finishes it"
curl -fsS -H "$auth" "$api/snapshots" | jq -r '.[] | "\(.created_at)  \(.status)  \(.name)"'
