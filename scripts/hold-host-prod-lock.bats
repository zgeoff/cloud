#!/usr/bin/env bats
# bats file_tags=suite:scripts
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
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-kubectl.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/hold-host-prod-lock.sh"
  # the stored Lease with each time replaced by whether it has a Lease's MicroTime form
  masked='.spec |= with_entries(if .key == "acquireTime" or .key == "renewTime" then .value |= test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.000000Z$") else . end)'
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/store/kube-system"
  : > "$tree/calls"
  create_stub_kubectl "$tree/bin" "$tree/store" "$tree/calls"
}

@test "it takes the lock as the invocation for 3000 seconds and writes status 0" {
  setup_test "$tree"
  before="$(date -u +%s)"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 LOCK_STATUS_FILE="$tree/lock-status" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take

  refute_output
  assert_stderr 'hold-prod-lock: took the prod lock as drift-check 0a1b2c3d4e5f60718293a4b5c6d7e8f9'

  run -0 diff - "$tree/lock-status" <<< 0
  after="$(date -u +%s)"
  actual="$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
  actual="$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
  jq -c "$masked" "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  run -0 diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"1"},"spec":{"holderIdentity":"drift-check 0a1b2c3d4e5f60718293a4b5c6d7e8f9","leaseDurationSeconds":3000,"acquireTime":true,"renewTime":true}}
EOF
}

@test "it writes the take s status and exits 0 when the take fails" {
  setup_test "$tree"
  echo 'system:serviceaccount:example-ns:example-account' > "$tree/store/forbidden"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 LOCK_STATUS_FILE="$tree/lock-status" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take

  assert_stderr 'Error from server (Forbidden): leases.coordination.k8s.io "cloud-prod-state" is forbidden: User "system:serviceaccount:example-ns:example-account" cannot get resource "leases" in API group "coordination.k8s.io" in the namespace "kube-system"'

  run -0 diff - "$tree/lock-status" <<< 1
}

@test "it releases the invocation s lock" {
  setup_test "$tree"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"drift-check 0a1b2c3d4e5f60718293a4b5c6d7e8f9","leaseDurationSeconds":3000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 LOCK_STATUS_FILE="$tree/lock-status" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release

  assert_stderr 'hold-prod-lock: released the prod lock as drift-check 0a1b2c3d4e5f60718293a4b5c6d7e8f9'

  jq -c .spec "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  run -0 diff - "$tree/lease" <<< '{"leaseDurationSeconds":3000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}'
  refute [ -e "$tree/lock-status" ]
  refute [ -L "$tree/lock-status" ]
}

@test "it refuses to run without its status file" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take

  assert_stderr 'hold-host-prod-lock: set LOCK_STATUS_FILE'

  run -0 diff /dev/null "$tree/calls"
}

@test "it rejects an unknown argument with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    INVOCATION_ID=0a1b2c3d4e5f60718293a4b5c6d7e8f9 LOCK_STATUS_FILE="$tree/lock-status" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" renew

  assert_stderr 'usage: hold-host-prod-lock.sh take|release'

  run -0 diff /dev/null "$tree/calls"
}
