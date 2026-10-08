#!/usr/bin/env bash
# Hermetic test for snapshot-geoffcloud.sh: it asks Onidel for a snapshot of geoffcloud's VM
# under the given name, then lists the account's snapshots, and never prints the API key. It
# touches no Onidel account: curl is a stand-in from test-lib that keeps the account's
# snapshots in the case's tree, and date reads a fixed instant. Every stand-in logs its argv
# as a JSON line. Each case runs the script under `env -i` with only the variables it sets
# and compares its whole stdout, stderr and call log, and its exact exit code.
#
#   bash scripts/test-snapshot-geoffcloud.sh
#   CASE='API key' bash scripts/test-snapshot-geoffcloud.sh   # the cases whose title holds it
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-onidel-curl.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-date.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/require-remote-tool-stubs.sh"

it_requests_a_snapshot_then_lists_the_account_snapshots() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"id":"5b0c2a8e-1f3d-4c6a-9e7b-2d4f6a8c0e1f","created_at":"2026-09-01T10:00:00.000000Z","name":"pre-imp-0.26","desc":"2026-09-01T09:59Z","size":20,"status":"available"}]' \
    > "$tree/onidel/snapshots.json"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_NOW=2026-10-08T12:34:56Z STUB_ONIDEL_KEY=onidel-test-key STUB_ONIDEL_VM=0f289413-258f-4115-ac81-252000998fe0 \
    STUB_ONIDEL_NOW=2026-10-08T12:34:57.000000Z STUB_ONIDEL_SNAPSHOT_ID=c1d45377-b2a9-4407-ab8d-6909c34dfaac \
    ONIDEL_API_KEY=onidel-test-key bash snapshot-geoffcloud.sh pre-imp-0.30) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << 'OUT'
requested snapshot pre-imp-0.30; it shows as available once Onidel finishes it
2026-09-01T10:00:00.000000Z  available  pre-imp-0.26
2026-10-08T12:34:57.000000Z  pending  pre-imp-0.30
OUT
  diff - "$tree/calls" << 'CALLS'
["date","-u","+%Y-%m-%dT%H:%MZ"]
["curl","-fsS","-X","POST","-H","Authorization: Bearer onidel-test-key","-H","content-type: application/json","--data","{\n  \"name\": \"pre-imp-0.30\",\n  \"desc\": \"2026-10-08T12:34Z\"\n}","https://api.cloud.onidel.com/vm/0f289413-258f-4115-ac81-252000998fe0/snapshot"]
["curl","-fsS","-H","Authorization: Bearer onidel-test-key","https://api.cloud.onidel.com/snapshots"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_stops_with_exit_1_and_its_usage_when_no_name_is_given() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/onidel/snapshots.json"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_NOW=2026-10-08T12:34:56Z STUB_ONIDEL_KEY=onidel-test-key STUB_ONIDEL_VM=0f289413-258f-4115-ac81-252000998fe0 \
    STUB_ONIDEL_NOW=2026-10-08T12:34:57.000000Z STUB_ONIDEL_SNAPSHOT_ID=c1d45377-b2a9-4407-ab8d-6909c34dfaac \
    ONIDEL_API_KEY=onidel-test-key bash snapshot-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'snapshot-geoffcloud.sh: line 9: 1: usage: snapshot-geoffcloud.sh <name>, such as pre-imp-0.26'
  diff /dev/null "$tree/calls"
  diff - "$tree/onidel/snapshots.json" <<< '[]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_with_exit_1_before_any_request_when_the_API_key_is_not_set() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/onidel/snapshots.json"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_NOW=2026-10-08T12:34:56Z STUB_ONIDEL_KEY=onidel-test-key STUB_ONIDEL_VM=0f289413-258f-4115-ac81-252000998fe0 \
    STUB_ONIDEL_NOW=2026-10-08T12:34:57.000000Z STUB_ONIDEL_SNAPSHOT_ID=c1d45377-b2a9-4407-ab8d-6909c34dfaac \
    bash snapshot-geoffcloud.sh pre-imp-0.30) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'snapshot-geoffcloud.sh: line 12: ONIDEL_API_KEY: run through op run --env-file=.env'
  diff /dev/null "$tree/calls"
  diff - "$tree/onidel/snapshots.json" <<< '[]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_with_curl_exit_22_and_lists_nothing_when_Onidel_refuses_the_snapshot() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/onidel/snapshots.json"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_NOW=2026-10-08T12:34:56Z STUB_ONIDEL_KEY=onidel-test-key STUB_ONIDEL_VM=0f289413-258f-4115-ac81-252000998fe0 \
    STUB_ONIDEL_NOW=2026-10-08T12:34:57.000000Z STUB_ONIDEL_SNAPSHOT_ID=c1d45377-b2a9-4407-ab8d-6909c34dfaac \
    STUB_ONIDEL_LIMIT_REACHED=1 ONIDEL_API_KEY=onidel-test-key bash snapshot-geoffcloud.sh pre-imp-0.30) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 403'
  diff - "$tree/calls" << 'CALLS'
["date","-u","+%Y-%m-%dT%H:%MZ"]
["curl","-fsS","-X","POST","-H","Authorization: Bearer onidel-test-key","-H","content-type: application/json","--data","{\n  \"name\": \"pre-imp-0.30\",\n  \"desc\": \"2026-10-08T12:34Z\"\n}","https://api.cloud.onidel.com/vm/0f289413-258f-4115-ac81-252000998fe0/snapshot"]
CALLS
  diff - "$tree/onidel/snapshots.json" <<< '[]'
  [ "$status" = 22 ] || { echo "exit $status, want 22" >&2; exit 1; }
}

it_stops_with_curl_exit_22_and_never_prints_the_key_when_Onidel_refuses_it() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/onidel/snapshots.json"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_NOW=2026-10-08T12:34:56Z STUB_ONIDEL_KEY=onidel-test-key STUB_ONIDEL_VM=0f289413-258f-4115-ac81-252000998fe0 \
    STUB_ONIDEL_NOW=2026-10-08T12:34:57.000000Z STUB_ONIDEL_SNAPSHOT_ID=c1d45377-b2a9-4407-ab8d-6909c34dfaac \
    ONIDEL_API_KEY=revoked-test-key bash snapshot-geoffcloud.sh pre-imp-0.30) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 401'
  diff - "$tree/calls" << 'CALLS'
["date","-u","+%Y-%m-%dT%H:%MZ"]
["curl","-fsS","-X","POST","-H","Authorization: Bearer revoked-test-key","-H","content-type: application/json","--data","{\n  \"name\": \"pre-imp-0.30\",\n  \"desc\": \"2026-10-08T12:34Z\"\n}","https://api.cloud.onidel.com/vm/0f289413-258f-4115-ac81-252000998fe0/snapshot"]
CALLS
  diff - "$tree/onidel/snapshots.json" <<< '[]'
  [ "$status" = 22 ] || { echo "exit $status, want 22" >&2; exit 1; }
}

it_exits_22_after_the_request_when_the_snapshot_list_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/onidel/snapshots.json"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_NOW=2026-10-08T12:34:56Z STUB_ONIDEL_KEY=onidel-test-key STUB_ONIDEL_VM=0f289413-258f-4115-ac81-252000998fe0 \
    STUB_ONIDEL_NOW=2026-10-08T12:34:57.000000Z STUB_ONIDEL_SNAPSHOT_ID=c1d45377-b2a9-4407-ab8d-6909c34dfaac \
    STUB_ONIDEL_LIST_STATUS=500 ONIDEL_API_KEY=onidel-test-key bash snapshot-geoffcloud.sh pre-imp-0.30) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'requested snapshot pre-imp-0.30; it shows as available once Onidel finishes it'
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 500'
  diff - "$tree/calls" << 'CALLS'
["date","-u","+%Y-%m-%dT%H:%MZ"]
["curl","-fsS","-X","POST","-H","Authorization: Bearer onidel-test-key","-H","content-type: application/json","--data","{\n  \"name\": \"pre-imp-0.30\",\n  \"desc\": \"2026-10-08T12:34Z\"\n}","https://api.cloud.onidel.com/vm/0f289413-258f-4115-ac81-252000998fe0/snapshot"]
["curl","-fsS","-H","Authorization: Bearer onidel-test-key","https://api.cloud.onidel.com/snapshots"]
CALLS
  diff - "$tree/onidel/snapshots.json" \
    <<< '[{"id":"c1d45377-b2a9-4407-ab8d-6909c34dfaac","created_at":"2026-10-08T12:34:57.000000Z","name":"pre-imp-0.30","desc":"2026-10-08T12:34Z","size":0,"status":"pending"}]'
  [ "$status" = 22 ] || { echo "exit $status, want 22" >&2; exit 1; }
}

# Runtime every case needs: the script in <tree>, the curl and date stand-ins with
# fail-closed stand-ins for every remote tool in <tree>/bin, checked so no call can reach a
# real remote tool, the empty call log, the Onidel account's directory, and the HOME and
# TMPDIR the script runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/onidel"
  : > "$tree/calls"
  cp "$(dirname "${BASH_SOURCE[0]}")/snapshot-geoffcloud.sh" "$tree/"
  create_stub_onidel_curl "$tree/bin"
  create_stub_date "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
