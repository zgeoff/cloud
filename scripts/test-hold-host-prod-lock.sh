#!/usr/bin/env bash
# Test for hold-host-prod-lock.sh: `take` holds the prod lock as the drift check's invocation for
# 3000 s and writes 0 to the status file, writes hold-prod-lock.sh's status and still exits 0 when
# the take fails, and `release` releases the invocation's lock; a missing input or a bad argument
# is a usage error.
#
# kubectl is create-stub-kubectl.sh, whose store holds the Lease. Each case runs the script under
# `env -i` and compares its whole stderr, the status file and the stored Lease, with each Lease
# time a take writes checked for its form and for falling between the clock's readings before and
# after the act.
#
#   bash scripts/test-hold-host-prod-lock.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-between.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-missing.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-kubectl.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hold-host-prod-lock.sh"
# the stored Lease with each time replaced by whether it has a Lease's MicroTime form
masked='.spec |= with_entries(if .key == "acquireTime" or .key == "renewTime" then .value |= test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.000000Z$") else . end)'

it_takes_the_lock_as_the_invocation_for_3000_seconds_and_writes_status_0() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 LOCK_STATUS_FILE="$tree/lock-status" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'hold-prod-lock: took the prod lock as drift-check 0a1b2c3d4e5f60718293a4b5c6d7e8f9'
  diff - "$tree/lock-status" <<< 0
  after="$(date -u +%s)"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the acquire time"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the renew time"
  jq -c "$masked" "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"1"},"spec":{"holderIdentity":"drift-check 0a1b2c3d4e5f60718293a4b5c6d7e8f9","leaseDurationSeconds":3000,"acquireTime":true,"renewTime":true}}
EOF
  assert_status 0 "$status"
}

it_writes_the_take_s_status_and_exits_0_when_the_take_fails() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo 'system:serviceaccount:example-ns:example-account' > "$tree/store/forbidden"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 LOCK_STATUS_FILE="$tree/lock-status" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'Error from server (Forbidden): leases.coordination.k8s.io "cloud-prod-state" is forbidden: User "system:serviceaccount:example-ns:example-account" cannot get resource "leases" in API group "coordination.k8s.io" in the namespace "kube-system"'
  diff - "$tree/lock-status" <<< 1
  assert_status 0 "$status"
}

it_releases_the_invocation_s_lock() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"drift-check 0a1b2c3d4e5f60718293a4b5c6d7e8f9","leaseDurationSeconds":3000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 LOCK_STATUS_FILE="$tree/lock-status" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'hold-prod-lock: released the prod lock as drift-check 0a1b2c3d4e5f60718293a4b5c6d7e8f9'
  jq -c .spec "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  diff - "$tree/lease" <<< '{"leaseDurationSeconds":3000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}'
  assert_missing "$tree/lock-status" "the release wrote a status"
  assert_status 0 "$status"
}

it_refuses_to_run_without_its_status_file() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'hold-host-prod-lock: set LOCK_STATUS_FILE'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

it_rejects_an_unknown_argument_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 LOCK_STATUS_FILE="$tree/lock-status" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" renew > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'usage: hold-host-prod-lock.sh take|release'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/store/kube-system"
  : > "$tree/calls"
  create_stub_kubectl "$tree/bin" "$tree/store" "$tree/calls"
}

run_cases
