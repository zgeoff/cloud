#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for hold-prod-lock.sh: `take` creates the Lease, takes one that no one holds, that it holds
# already or whose holder let it run out, waits while another holder holds it and takes it once
# that holder releases it (a Deploy prod run behind a drift check, and a drift check behind a
# Deploy prod run), reads again after it loses a race, exits 75 when the lock stays held past the
# wait, and exits 1 with kubectl's error on any other answer; `release` clears its own holder, and
# leaves a Lease that another holder holds, that it lost in a race, or that does not exist; `check`
# passes while the Lease names its holder, a lease that ran out included, exits 3 for a Lease that
# another holder holds or that does not exist, and exits 1 with kubectl's error; and each rejects a
# bad argument with its usage.
#
# kubectl is create-stub-kubectl.sh, whose store holds the Lease. A case that waits runs the take
# in the background with a short real pause, and releases the lock from the case once the take has
# said who holds it. Each case runs the script under `env -i` and compares its whole stderr, the
# stored Lease and the kubectl calls, with each Lease time a take writes checked for its form and
# for falling between the clock's readings before and after the act.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-kubectl.sh'
  load 'src/test-utils/shell/wait-for.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/hold-prod-lock.sh"
  # the stored Lease with each time replaced by whether it has a Lease's MicroTime form
  masked='.spec |= with_entries(if .key == "acquireTime" or .key == "renewTime" then .value |= test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.000000Z$") else . end)'
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
  kill "$taker" 2> /dev/null || true
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/store/kube-system"
  : > "$tree/calls"
  create_stub_kubectl "$tree/bin" "$tree/store" "$tree/calls"
}

@test "it takes the lock by creating the lease when there is none" {
  setup_test "$tree"
  before="$(date -u +%s)"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'deploy-prod 4321' 6000 3300

  refute_output
  assert_stderr 'hold-prod-lock: took the prod lock as deploy-prod 4321'

  after="$(date -u +%s)"
  actual="$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
  actual="$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
  jq -c "$masked" "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  run -0 diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"1"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":true,"renewTime":true}}
EOF
  run -0 diff - "$tree/calls" << 'EOF'
["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]
["kubectl","--request-timeout=30s","create","--filename","-"]
EOF
}

@test "it takes a lease that no one holds by replacing it at its version" {
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"8","uid":"example-uid"},"spec":{"leaseDurationSeconds":3000,"acquireTime":"2026-10-20T05:41:00.000000Z","renewTime":"2026-10-20T05:41:00.000000Z"}}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'drift-check 0a1b2c3d' 3000 6300

  assert_stderr 'hold-prod-lock: took the prod lock as drift-check 0a1b2c3d'

  after="$(date -u +%s)"
  actual="$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
  actual="$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
  jq -c "$masked" "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  run -0 diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"9","uid":"example-uid"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":true,"renewTime":true}}
EOF
  run -0 diff - "$tree/calls" << 'EOF'
["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]
["kubectl","--request-timeout=30s","replace","--filename","-"]
EOF
}

@test "it takes the lock again when it holds it already" {
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"3"},"spec":{"holderIdentity":"deploy-prod 4322","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'deploy-prod 4322' 6000 3300

  assert_stderr 'hold-prod-lock: took the prod lock as deploy-prod 4322'

  after="$(date -u +%s)"
  actual="$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
  actual="$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
  jq -c "$masked" "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  run -0 diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"4"},"spec":{"holderIdentity":"deploy-prod 4322","leaseDurationSeconds":6000,"acquireTime":true,"renewTime":true}}
EOF
}

@test "it takes over a lease whose holder let it run out" {
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"5"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2026-01-01T00:00:00.000000Z","renewTime":"2026-01-01T00:00:00.000000Z"}}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'drift-check 0a1b2c3d' 3000 6300

  assert_stderr - << 'EOF'
hold-prod-lock: deploy-prod 4321 let the prod lock run out at 2026-01-01T01:40:00.000000Z; taking it over
hold-prod-lock: took the prod lock as drift-check 0a1b2c3d
EOF

  after="$(date -u +%s)"
  actual="$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
  actual="$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
  jq -c "$masked" "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  run -0 diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"6"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":true,"renewTime":true}}
EOF
}

@test "it makes a deploy prod run wait while a drift check holds the lock and take it once released" {
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" LOCK_WAIT_DELAY=0.1 \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'deploy-prod 4321' 6000 3300 \
    > "$tree/out" 2> "$tree/err" 3>&- &
  taker=$!
  wait_for 10 "the take to wait" grep -q 'holds the prod lock' "$tree/err"
  kill -0 "$taker"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release 'drift-check 0a1b2c3d' 2> "$tree/release-err"

  wait_status=0
  wait "$taker" || wait_status=$?
  assert_equal "$wait_status" 0

  uniq "$tree/err" > "$tree/waits"
  run -0 diff - "$tree/waits" << 'EOF'
hold-prod-lock: drift-check 0a1b2c3d holds the prod lock until 2099-01-01T00:50:00.000000Z; asking again in 0.1s
hold-prod-lock: took the prod lock as deploy-prod 4321
EOF
  run -0 diff - "$tree/release-err" <<< 'hold-prod-lock: released the prod lock as drift-check 0a1b2c3d'
  jq -r .spec.holderIdentity "$tree/store/kube-system/cloud-prod-state.json" > "$tree/holder"
  run -0 diff - "$tree/holder" <<< 'deploy-prod 4321'
}

@test "it makes a drift check wait while a deploy prod run holds the lock and take it once released" {
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" LOCK_WAIT_DELAY=0.1 \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'drift-check 0a1b2c3d' 3000 6300 \
    > "$tree/out" 2> "$tree/err" 3>&- &
  taker=$!
  wait_for 10 "the take to wait" grep -q 'holds the prod lock' "$tree/err"
  kill -0 "$taker"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release 'deploy-prod 4321' 2> "$tree/release-err"

  wait_status=0
  wait "$taker" || wait_status=$?
  assert_equal "$wait_status" 0

  uniq "$tree/err" > "$tree/waits"
  run -0 diff - "$tree/waits" << 'EOF'
hold-prod-lock: deploy-prod 4321 holds the prod lock until 2099-01-01T01:40:00.000000Z; asking again in 0.1s
hold-prod-lock: took the prod lock as drift-check 0a1b2c3d
EOF
  run -0 diff - "$tree/release-err" <<< 'hold-prod-lock: released the prod lock as deploy-prod 4321'
  jq -r .spec.holderIdentity "$tree/store/kube-system/cloud-prod-state.json" > "$tree/holder"
  run -0 diff - "$tree/holder" <<< 'drift-check 0a1b2c3d'
}

@test "it exits 75 when another holder still holds the lock after the wait" {
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  run -75 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'drift-check 0a1b2c3d' 3000 0

  assert_stderr 'hold-prod-lock: deploy-prod 4321 still holds the prod lock after 0s'

  jq -r .spec.holderIdentity "$tree/store/kube-system/cloud-prod-state.json" > "$tree/holder"
  run -0 diff - "$tree/holder" <<< 'deploy-prod 4321'
}

@test "it reads the lease again after another taker wins the race for it" {
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"leaseDurationSeconds":3000}}
EOF
  cat > "$tree/store/race.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  run -75 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'drift-check 0a1b2c3d' 3000 0

  assert_stderr 'hold-prod-lock: deploy-prod 4321 still holds the prod lock after 0s'

  run -0 diff - "$tree/calls" << 'EOF'
["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]
["kubectl","--request-timeout=30s","replace","--filename","-"]
["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]
EOF
  jq -r .spec.holderIdentity "$tree/store/kube-system/cloud-prod-state.json" > "$tree/holder"
  run -0 diff - "$tree/holder" <<< 'deploy-prod 4321'
}

@test "it exits 1 with kubectl s error when the api refuses the read" {
  setup_test "$tree"
  before="$(date -u +%s)"
  echo 'system:serviceaccount:example-ns:example-account' > "$tree/store/forbidden"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'drift-check 0a1b2c3d' 3000 6300

  refute_output
  assert_stderr 'Error from server (Forbidden): leases.coordination.k8s.io "cloud-prod-state" is forbidden: User "system:serviceaccount:example-ns:example-account" cannot get resource "leases" in API group "coordination.k8s.io" in the namespace "kube-system"'
}

@test "it releases the lock it holds by clearing the holder" {
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release 'deploy-prod 4321'

  refute_output
  assert_stderr 'hold-prod-lock: released the prod lock as deploy-prod 4321'

  jq -c . "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  run -0 diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"3"},"spec":{"leaseDurationSeconds":6000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}}
EOF
}

@test "it leaves a lock that another holder took over" {
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"4"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release 'deploy-prod 4321'

  assert_stderr 'hold-prod-lock: deploy-prod 4321 does not hold the prod lock; leaving it'

  jq -r '"\(.metadata.resourceVersion) \(.spec.holderIdentity)"' "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  run -0 diff - "$tree/lease" <<< '4 drift-check 0a1b2c3d'
}

@test "it leaves a lock that another holder took while it released it" {
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2026-01-01T00:00:00.000000Z","renewTime":"2026-01-01T00:00:00.000000Z"}}
EOF
  cat > "$tree/store/race.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release 'deploy-prod 4321'

  assert_stderr 'hold-prod-lock: deploy-prod 4321 does not hold the prod lock; leaving it'

  jq -r .spec.holderIdentity "$tree/store/kube-system/cloud-prod-state.json" > "$tree/holder"
  run -0 diff - "$tree/holder" <<< 'drift-check 0a1b2c3d'
}

@test "it leaves nothing to release when there is no lease" {
  setup_test "$tree"
  before="$(date -u +%s)"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release 'deploy-prod 4321'

  assert_stderr 'hold-prod-lock: deploy-prod 4321 does not hold the prod lock; leaving it'

  run -0 diff - "$tree/calls" <<< '["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]'
}

@test "it checks a lock that it holds and whose lease has not run out" {
  setup_test "$tree"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" check 'deploy-prod 4321'

  refute_output
  assert_stderr 'hold-prod-lock: deploy-prod 4321 holds the prod lock until 2099-01-01T01:40:00.000000Z'

  run -0 diff - "$tree/calls" <<< '["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]'
}

@test "it exits 3 on a check of a lock that another holder holds" {
  setup_test "$tree"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"4"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  run -3 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" check 'deploy-prod 4321'

  refute_output
  assert_stderr 'hold-prod-lock: deploy-prod 4321 does not hold the prod lock; its holder is drift-check 0a1b2c3d'
}

@test "it passes a check of a lock whose lease ran out while no one took it over" {
  setup_test "$tree"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2026-01-01T00:00:00.000000Z","renewTime":"2026-01-01T00:00:00.000000Z"}}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" check 'deploy-prod 4321'

  refute_output
  assert_stderr 'hold-prod-lock: deploy-prod 4321 holds the prod lock; its lease ran out at 2026-01-01T01:40:00.000000Z, and no one took it over'
}

@test "it exits 3 on a check when there is no lease" {
  setup_test "$tree"

  run -3 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" check 'deploy-prod 4321'

  refute_output
  assert_stderr 'hold-prod-lock: deploy-prod 4321 does not hold the prod lock; its holder is no one'
}

@test "it exits 1 with kubectl s error when the api refuses a check s read" {
  setup_test "$tree"
  echo 'system:serviceaccount:example-ns:example-account' > "$tree/store/forbidden"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" check 'deploy-prod 4321'

  refute_output
  assert_stderr 'Error from server (Forbidden): leases.coordination.k8s.io "cloud-prod-state" is forbidden: User "system:serviceaccount:example-ns:example-account" cannot get resource "leases" in API group "coordination.k8s.io" in the namespace "kube-system"'
}

@test "it rejects a take without a whole number of lease seconds with its usage" {
  setup_test "$tree"
  before="$(date -u +%s)"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'deploy-prod 4321' 10m 3300

  assert_stderr 'usage: hold-prod-lock.sh take <holder> <lease seconds> <wait seconds> | release <holder> | check <holder>'

  run -0 diff /dev/null "$tree/calls"
}

@test "it rejects a release with an empty holder with its usage" {
  setup_test "$tree"
  before="$(date -u +%s)"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release ''

  assert_stderr 'usage: hold-prod-lock.sh take <holder> <lease seconds> <wait seconds> | release <holder> | check <holder>'

  run -0 diff /dev/null "$tree/calls"
}

@test "it rejects a check without a holder with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" check

  assert_stderr 'usage: hold-prod-lock.sh take <holder> <lease seconds> <wait seconds> | release <holder> | check <holder>'

  run -0 diff /dev/null "$tree/calls"
}
