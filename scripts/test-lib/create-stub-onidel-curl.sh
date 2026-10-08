# shellcheck shell=bash
# create_stub_onidel_curl <bin>: writes <bin>/curl, a stand-in for curl calling the Onidel
# API as snapshot-geoffcloud.sh does (curl -fsS). The account's snapshots are
# STUB_TREE/onidel/snapshots.json, an array in the spec's Snapshots shape
# (provider/spec/onidel.yaml); its one VM is STUB_ONIDEL_VM and its API key
# STUB_ONIDEL_KEY. It logs each call's argv as a JSON line to STUB_TREE/calls and answers:
#
# - `-X POST -H <auth> -H content-type: application/json --data <json> <api>/vm/<id>/snapshot`:
#   appends a pending snapshot with the body's name and desc, created_at STUB_ONIDEL_NOW and
#   id STUB_ONIDEL_SNAPSHOT_ID, and prints the spec's 201 body {"snapshot_id": …};
#   with STUB_ONIDEL_LIMIT_REACHED=1 it answers the spec's 403 instead;
# - `-H <auth> <api>/snapshots`: prints snapshots.json; with STUB_ONIDEL_LIST_STATUS it
#   answers that HTTP status instead;
# - a bearer other than STUB_ONIDEL_KEY gets the spec's 401, and another VM its 404.
#
# An HTTP error goes as curl -fsS reports it: nothing on stdout, "curl: (22) The requested
# URL returned error: <status>" on stderr, exit 22 (curl 8.5.0, CI's ubuntu-24.04, and
# 8.22.0 print the same). Any other call ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_onidel_curl() {
  local bin="$1"
  cat > "$bin/curl" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' curl "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
api=https://api.cloud.onidel.com
fail() {
  echo "curl: (22) The requested URL returned error: $1" >&2
  exit 22
}
if [ "$#" = 10 ] && [ "$1 $2 $3 $4 $6 $7 $8" = "-fsS -X POST -H -H content-type: application/json --data" ] &&
  [[ "$5" == "Authorization: Bearer "* ]] && [[ "${10}" =~ ^$api/vm/([^/]+)/snapshot$ ]]; then
  if [ "$5" != "Authorization: Bearer ${STUB_ONIDEL_KEY:-}" ]; then fail 401; fi
  if [ "${BASH_REMATCH[1]}" != "$STUB_ONIDEL_VM" ]; then fail 404; fi
  if [ -n "${STUB_ONIDEL_LIMIT_REACHED:-}" ]; then fail 403; fi
  jq -c --argjson body "$9" --arg id "$STUB_ONIDEL_SNAPSHOT_ID" --arg now "$STUB_ONIDEL_NOW" \
    '. + [{id: $id, created_at: $now, name: $body.name, desc: $body.desc, size: 0, status: "pending"}]' \
    "$STUB_TREE/onidel/snapshots.json" > "$STUB_TREE/onidel/snapshots.next"
  mv "$STUB_TREE/onidel/snapshots.next" "$STUB_TREE/onidel/snapshots.json"
  jq -cn --arg id "$STUB_ONIDEL_SNAPSHOT_ID" '{snapshot_id: $id}'
elif [ "$#" = 4 ] && [ "$1 $2" = "-fsS -H" ] && [[ "$3" == "Authorization: Bearer "* ]] && [ "$4" = "$api/snapshots" ]; then
  if [ "$3" != "Authorization: Bearer ${STUB_ONIDEL_KEY:-}" ]; then fail 401; fi
  if [ -n "${STUB_ONIDEL_LIST_STATUS:-}" ]; then fail "$STUB_ONIDEL_LIST_STATUS"; fi
  jq -c . "$STUB_TREE/onidel/snapshots.json"
else
  echo "unexpected: $*" >&2
  exit 97
fi
STUB
  chmod +x "$bin/curl"
}
