#!/usr/bin/env bash
# Test for create-stub-onidel-curl.sh: the curl stand-in takes a snapshot of its one VM,
# lists the account's snapshots in the spec's Snapshots shape, answers the spec's 401, 403
# and 404 as curl -fsS reports an HTTP error, and fails closed on any other call. One case
# pins that report against the real curl, refused with a 401 by the impd stand-in on
# loopback.
#
#   bash scripts/test-lib/test-create-stub-onidel-curl.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-onidel-curl.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-stub-impd.sh"

it_takes_a_pending_snapshot_and_prints_its_id() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/onidel/snapshots.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_ONIDEL_KEY=k1 STUB_ONIDEL_VM=vm-1 STUB_ONIDEL_NOW=2026-10-08T12:00:00.000000Z STUB_ONIDEL_SNAPSHOT_ID=snap-1 \
    curl -fsS -X POST -H 'Authorization: Bearer k1' -H 'content-type: application/json' \
    --data '{"name":"pre-x","desc":"before x"}' https://api.cloud.onidel.com/vm/vm-1/snapshot \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '{"snapshot_id":"snap-1"}'
  diff /dev/null "$tree/err"
  diff - "$tree/onidel/snapshots.json" \
    <<< '[{"id":"snap-1","created_at":"2026-10-08T12:00:00.000000Z","name":"pre-x","desc":"before x","size":0,"status":"pending"}]'
  diff - "$tree/calls" << 'CALLS'
["curl","-fsS","-X","POST","-H","Authorization: Bearer k1","-H","content-type: application/json","--data","{\"name\":\"pre-x\",\"desc\":\"before x\"}","https://api.cloud.onidel.com/vm/vm-1/snapshot"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_lists_the_account_snapshots() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"id":"snap-1","created_at":"2026-10-08T12:00:00.000000Z","name":"pre-x","desc":"before x","size":20,"status":"available"}]' \
    > "$tree/onidel/snapshots.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_ONIDEL_KEY=k1 \
    curl -fsS -H 'Authorization: Bearer k1' https://api.cloud.onidel.com/snapshots > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" \
    <<< '[{"id":"snap-1","created_at":"2026-10-08T12:00:00.000000Z","name":"pre-x","desc":"before x","size":20,"status":"available"}]'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["curl","-fsS","-H","Authorization: Bearer k1","https://api.cloud.onidel.com/snapshots"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_refuses_a_snapshot_with_another_bearer_as_curl_reports_a_401() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/onidel/snapshots.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_ONIDEL_KEY=k1 STUB_ONIDEL_VM=vm-1 STUB_ONIDEL_NOW=2026-10-08T12:00:00.000000Z STUB_ONIDEL_SNAPSHOT_ID=snap-1 \
    curl -fsS -X POST -H 'Authorization: Bearer k2' -H 'content-type: application/json' \
    --data '{"name":"pre-x","desc":"before x"}' https://api.cloud.onidel.com/vm/vm-1/snapshot \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 401'
  diff - "$tree/onidel/snapshots.json" <<< '[]'
  diff - "$tree/calls" << 'CALLS'
["curl","-fsS","-X","POST","-H","Authorization: Bearer k2","-H","content-type: application/json","--data","{\"name\":\"pre-x\",\"desc\":\"before x\"}","https://api.cloud.onidel.com/vm/vm-1/snapshot"]
CALLS
  [ "$status" = 22 ] || { echo "exit $status, want 22" >&2; exit 1; }
}

it_refuses_a_snapshot_of_another_VM_as_curl_reports_a_404() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/onidel/snapshots.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_ONIDEL_KEY=k1 STUB_ONIDEL_VM=vm-1 STUB_ONIDEL_NOW=2026-10-08T12:00:00.000000Z STUB_ONIDEL_SNAPSHOT_ID=snap-1 \
    curl -fsS -X POST -H 'Authorization: Bearer k1' -H 'content-type: application/json' \
    --data '{"name":"pre-x","desc":"before x"}' https://api.cloud.onidel.com/vm/vm-2/snapshot \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 404'
  diff - "$tree/onidel/snapshots.json" <<< '[]'
  diff - "$tree/calls" << 'CALLS'
["curl","-fsS","-X","POST","-H","Authorization: Bearer k1","-H","content-type: application/json","--data","{\"name\":\"pre-x\",\"desc\":\"before x\"}","https://api.cloud.onidel.com/vm/vm-2/snapshot"]
CALLS
  [ "$status" = 22 ] || { echo "exit $status, want 22" >&2; exit 1; }
}

it_refuses_a_snapshot_over_the_limit_as_curl_reports_a_403() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/onidel/snapshots.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_ONIDEL_KEY=k1 STUB_ONIDEL_VM=vm-1 STUB_ONIDEL_NOW=2026-10-08T12:00:00.000000Z STUB_ONIDEL_SNAPSHOT_ID=snap-1 \
    STUB_ONIDEL_LIMIT_REACHED=1 curl -fsS -X POST -H 'Authorization: Bearer k1' -H 'content-type: application/json' \
    --data '{"name":"pre-x","desc":"before x"}' https://api.cloud.onidel.com/vm/vm-1/snapshot \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 403'
  diff - "$tree/onidel/snapshots.json" <<< '[]'
  diff - "$tree/calls" << 'CALLS'
["curl","-fsS","-X","POST","-H","Authorization: Bearer k1","-H","content-type: application/json","--data","{\"name\":\"pre-x\",\"desc\":\"before x\"}","https://api.cloud.onidel.com/vm/vm-1/snapshot"]
CALLS
  [ "$status" = 22 ] || { echo "exit $status, want 22" >&2; exit 1; }
}

it_refuses_the_list_with_another_bearer_as_curl_reports_a_401() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/onidel/snapshots.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_ONIDEL_KEY=k1 \
    curl -fsS -H 'Authorization: Bearer k2' https://api.cloud.onidel.com/snapshots > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 401'
  diff - "$tree/calls" <<< '["curl","-fsS","-H","Authorization: Bearer k2","https://api.cloud.onidel.com/snapshots"]'
  [ "$status" = 22 ] || { echo "exit $status, want 22" >&2; exit 1; }
}

it_fails_the_list_with_the_named_HTTP_status() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/onidel/snapshots.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_ONIDEL_KEY=k1 \
    STUB_ONIDEL_LIST_STATUS=500 curl -fsS -H 'Authorization: Bearer k1' https://api.cloud.onidel.com/snapshots \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 500'
  diff - "$tree/calls" <<< '["curl","-fsS","-H","Authorization: Bearer k1","https://api.cloud.onidel.com/snapshots"]'
  [ "$status" = 22 ] || { echo "exit $status, want 22" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/onidel/snapshots.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_ONIDEL_KEY=k1 \
    curl -fsS -H 'Authorization: Bearer k1' https://api.cloud.onidel.com/vm/vm-1 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -fsS -H Authorization: Bearer k1 https://api.cloud.onidel.com/vm/vm-1'
  diff - "$tree/calls" <<< '["curl","-fsS","-H","Authorization: Bearer k1","https://api.cloud.onidel.com/vm/vm-1"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# Pins the stand-in's HTTP error report to the real curl's: the impd stand-in on loopback
# refuses a bearer it does not hold with a 401, which the real curl -fsS reports.
it_reports_an_HTTP_error_as_the_real_curl_does() {
  local status=0 real_status=0
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/impd/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/onidel/snapshots.json"
  mkdir "$tree/impd"
  start_stub_impd "$tree/impd"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" curl -q --noproxy '*' -fsS -X POST \
    -H 'Authorization: Bearer k2' "http://127.0.0.1:$(cat "$tree/impd/port")/rpc/tokens/whoami" \
    > "$tree/real-out" 2> "$tree/real-err" || real_status=$?

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_ONIDEL_KEY=k1 \
    curl -fsS -H 'Authorization: Bearer k2' https://api.cloud.onidel.com/snapshots > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/real-out" "$tree/out"
  diff "$tree/real-err" "$tree/err"
  diff - "$tree/calls" <<< '["curl","-fsS","-H","Authorization: Bearer k2","https://api.cloud.onidel.com/snapshots"]'
  [ "$status" = "$real_status" ] || { echo "exit $status, want $real_status" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, with fail-closed stand-ins for every
# remote tool, checked so no call can reach a real remote tool, the empty call log, the
# account's directory, and the HOME and TMPDIR the stand-in runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/onidel"
  : > "$tree/calls"
  create_stub_onidel_curl "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
