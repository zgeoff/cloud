#!/usr/bin/env bash
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
#   bash scripts/test-hold-prod-lock.sh
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # each create_case_tree cleanup expands when its case exits
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-between.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-kubectl.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/wait-for.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hold-prod-lock.sh"
# the stored Lease with each time replaced by whether it has a Lease's MicroTime form
masked='.spec |= with_entries(if .key == "acquireTime" or .key == "renewTime" then .value |= test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.000000Z$") else . end)'

it_takes_the_lock_by_creating_the_lease_when_there_is_none() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'deploy-prod 4321' 6000 3300 \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'hold-prod-lock: took the prod lock as deploy-prod 4321'
  after="$(date -u +%s)"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the acquire time"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the renew time"
  jq -c "$masked" "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"1"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":true,"renewTime":true}}
EOF
  diff - "$tree/calls" << 'EOF'
["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]
["kubectl","--request-timeout=30s","create","--filename","-"]
EOF
  assert_status 0 "$status"
}

it_takes_a_lease_that_no_one_holds_by_replacing_it_at_its_version() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"8","uid":"example-uid"},"spec":{"leaseDurationSeconds":3000,"acquireTime":"2026-10-20T05:41:00.000000Z","renewTime":"2026-10-20T05:41:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'drift-check 0a1b2c3d' 3000 6300 \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'hold-prod-lock: took the prod lock as drift-check 0a1b2c3d'
  after="$(date -u +%s)"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the acquire time"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the renew time"
  jq -c "$masked" "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"9","uid":"example-uid"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":true,"renewTime":true}}
EOF
  diff - "$tree/calls" << 'EOF'
["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]
["kubectl","--request-timeout=30s","replace","--filename","-"]
EOF
  assert_status 0 "$status"
}

it_takes_the_lock_again_when_it_holds_it_already() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"3"},"spec":{"holderIdentity":"deploy-prod 4322","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'deploy-prod 4322' 6000 3300 \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'hold-prod-lock: took the prod lock as deploy-prod 4322'
  after="$(date -u +%s)"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the acquire time"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the renew time"
  jq -c "$masked" "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"4"},"spec":{"holderIdentity":"deploy-prod 4322","leaseDurationSeconds":6000,"acquireTime":true,"renewTime":true}}
EOF
  assert_status 0 "$status"
}

it_takes_over_a_lease_whose_holder_let_it_run_out() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"5"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2026-01-01T00:00:00.000000Z","renewTime":"2026-01-01T00:00:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'drift-check 0a1b2c3d' 3000 6300 \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << 'EOF'
hold-prod-lock: deploy-prod 4321 let the prod lock run out at 2026-01-01T01:40:00.000000Z; taking it over
hold-prod-lock: took the prod lock as drift-check 0a1b2c3d
EOF
  after="$(date -u +%s)"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the acquire time"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the renew time"
  jq -c "$masked" "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"6"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":true,"renewTime":true}}
EOF
  assert_status 0 "$status"
}

it_makes_a_deploy_prod_run_wait_while_a_drift_check_holds_the_lock_and_take_it_once_released() {
  local status=0
  create_case_tree 'kill "$taker" 2> /dev/null || true'
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" LOCK_WAIT_DELAY=0.1 \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'deploy-prod 4321' 6000 3300 \
    > "$tree/out" 2> "$tree/err" &
  taker=$!
  wait_for 10 "the take to wait" grep -q 'holds the prod lock' "$tree/err"
  kill -0 "$taker"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release 'drift-check 0a1b2c3d' 2> "$tree/release-err"

  wait "$taker" || status=$?

  uniq "$tree/err" > "$tree/waits"
  diff - "$tree/waits" << 'EOF'
hold-prod-lock: drift-check 0a1b2c3d holds the prod lock until 2099-01-01T00:50:00.000000Z; asking again in 0.1s
hold-prod-lock: took the prod lock as deploy-prod 4321
EOF
  diff - "$tree/release-err" <<< 'hold-prod-lock: released the prod lock as drift-check 0a1b2c3d'
  jq -r .spec.holderIdentity "$tree/store/kube-system/cloud-prod-state.json" > "$tree/holder"
  diff - "$tree/holder" <<< 'deploy-prod 4321'
  assert_status 0 "$status"
}

it_makes_a_drift_check_wait_while_a_deploy_prod_run_holds_the_lock_and_take_it_once_released() {
  local status=0
  create_case_tree 'kill "$taker" 2> /dev/null || true'
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" LOCK_WAIT_DELAY=0.1 \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'drift-check 0a1b2c3d' 3000 6300 \
    > "$tree/out" 2> "$tree/err" &
  taker=$!
  wait_for 10 "the take to wait" grep -q 'holds the prod lock' "$tree/err"
  kill -0 "$taker"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release 'deploy-prod 4321' 2> "$tree/release-err"

  wait "$taker" || status=$?

  uniq "$tree/err" > "$tree/waits"
  diff - "$tree/waits" << 'EOF'
hold-prod-lock: deploy-prod 4321 holds the prod lock until 2099-01-01T01:40:00.000000Z; asking again in 0.1s
hold-prod-lock: took the prod lock as drift-check 0a1b2c3d
EOF
  diff - "$tree/release-err" <<< 'hold-prod-lock: released the prod lock as deploy-prod 4321'
  jq -r .spec.holderIdentity "$tree/store/kube-system/cloud-prod-state.json" > "$tree/holder"
  diff - "$tree/holder" <<< 'drift-check 0a1b2c3d'
  assert_status 0 "$status"
}

it_exits_75_when_another_holder_still_holds_the_lock_after_the_wait() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'drift-check 0a1b2c3d' 3000 0 \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'hold-prod-lock: deploy-prod 4321 still holds the prod lock after 0s'
  jq -r .spec.holderIdentity "$tree/store/kube-system/cloud-prod-state.json" > "$tree/holder"
  diff - "$tree/holder" <<< 'deploy-prod 4321'
  assert_status 75 "$status"
}

it_reads_the_lease_again_after_another_taker_wins_the_race_for_it() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"leaseDurationSeconds":3000}}
EOF
  cat > "$tree/store/race.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'drift-check 0a1b2c3d' 3000 0 \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'hold-prod-lock: deploy-prod 4321 still holds the prod lock after 0s'
  diff - "$tree/calls" << 'EOF'
["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]
["kubectl","--request-timeout=30s","replace","--filename","-"]
["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]
EOF
  jq -r .spec.holderIdentity "$tree/store/kube-system/cloud-prod-state.json" > "$tree/holder"
  diff - "$tree/holder" <<< 'deploy-prod 4321'
  assert_status 75 "$status"
}

it_exits_1_with_kubectl_s_error_when_the_api_refuses_the_read() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"
  echo 'system:serviceaccount:example-ns:example-account' > "$tree/store/forbidden"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'drift-check 0a1b2c3d' 3000 6300 \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error from server (Forbidden): leases.coordination.k8s.io "cloud-prod-state" is forbidden: User "system:serviceaccount:example-ns:example-account" cannot get resource "leases" in API group "coordination.k8s.io" in the namespace "kube-system"'
  assert_status 1 "$status"
}

it_releases_the_lock_it_holds_by_clearing_the_holder() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release 'deploy-prod 4321' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'hold-prod-lock: released the prod lock as deploy-prod 4321'
  jq -c . "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"3"},"spec":{"leaseDurationSeconds":6000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}}
EOF
  assert_status 0 "$status"
}

it_leaves_a_lock_that_another_holder_took_over() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"4"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release 'deploy-prod 4321' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'hold-prod-lock: deploy-prod 4321 does not hold the prod lock; leaving it'
  jq -r '"\(.metadata.resourceVersion) \(.spec.holderIdentity)"' "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  diff - "$tree/lease" <<< '4 drift-check 0a1b2c3d'
  assert_status 0 "$status"
}

it_leaves_a_lock_that_another_holder_took_while_it_released_it() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2026-01-01T00:00:00.000000Z","renewTime":"2026-01-01T00:00:00.000000Z"}}
EOF
  cat > "$tree/store/race.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release 'deploy-prod 4321' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'hold-prod-lock: deploy-prod 4321 does not hold the prod lock; leaving it'
  jq -r .spec.holderIdentity "$tree/store/kube-system/cloud-prod-state.json" > "$tree/holder"
  diff - "$tree/holder" <<< 'drift-check 0a1b2c3d'
  assert_status 0 "$status"
}

it_leaves_nothing_to_release_when_there_is_no_lease() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release 'deploy-prod 4321' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'hold-prod-lock: deploy-prod 4321 does not hold the prod lock; leaving it'
  diff - "$tree/calls" <<< '["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]'
  assert_status 0 "$status"
}

it_checks_a_lock_that_it_holds_and_whose_lease_has_not_run_out() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" check 'deploy-prod 4321' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'hold-prod-lock: deploy-prod 4321 holds the prod lock until 2099-01-01T01:40:00.000000Z'
  diff - "$tree/calls" <<< '["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]'
  assert_status 0 "$status"
}

it_exits_3_on_a_check_of_a_lock_that_another_holder_holds() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"4"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" check 'deploy-prod 4321' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'hold-prod-lock: deploy-prod 4321 does not hold the prod lock; its holder is drift-check 0a1b2c3d'
  assert_status 3 "$status"
}

it_passes_a_check_of_a_lock_whose_lease_ran_out_while_no_one_took_it_over() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 4321","leaseDurationSeconds":6000,"acquireTime":"2026-01-01T00:00:00.000000Z","renewTime":"2026-01-01T00:00:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" check 'deploy-prod 4321' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'hold-prod-lock: deploy-prod 4321 holds the prod lock; its lease ran out at 2026-01-01T01:40:00.000000Z, and no one took it over'
  assert_status 0 "$status"
}

it_exits_3_on_a_check_when_there_is_no_lease() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" check 'deploy-prod 4321' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'hold-prod-lock: deploy-prod 4321 does not hold the prod lock; its holder is no one'
  assert_status 3 "$status"
}

it_exits_1_with_kubectl_s_error_when_the_api_refuses_a_check_s_read() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo 'system:serviceaccount:example-ns:example-account' > "$tree/store/forbidden"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" check 'deploy-prod 4321' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error from server (Forbidden): leases.coordination.k8s.io "cloud-prod-state" is forbidden: User "system:serviceaccount:example-ns:example-account" cannot get resource "leases" in API group "coordination.k8s.io" in the namespace "kube-system"'
  assert_status 1 "$status"
}

it_rejects_a_take_without_a_whole_number_of_lease_seconds_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" take 'deploy-prod 4321' 10m 3300 \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'usage: hold-prod-lock.sh take <holder> <lease seconds> <wait seconds> | release <holder> | check <holder>'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

it_rejects_a_release_with_an_empty_holder_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" release '' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'usage: hold-prod-lock.sh take <holder> <lease seconds> <wait seconds> | release <holder> | check <holder>'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

it_rejects_a_check_without_a_holder_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    KUBECONFIG="$tree/kubeconfig" bash "$script" check \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'usage: hold-prod-lock.sh take <holder> <lease seconds> <wait seconds> | release <holder> | check <holder>'
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
