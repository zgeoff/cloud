#!/usr/bin/env bash
# Test for hold-deploy-prod-lock.sh: `take` writes the deploy vault's kubeconfig to KUBECONFIG with
# mode 0600 and holds the prod lock as the run for 6000 s, takes back the hold that an earlier
# attempt of the run left, and leaves no kubeconfig and takes nothing when 1Password does not
# answer; `release` releases the run's lock and removes
# the kubeconfig, and does nothing without one; a missing input or a bad argument is a usage error.
#
# op is create-stub-op-read.sh, whose vault directory holds the kubeconfig, and kubectl is
# create-stub-kubectl.sh, whose store holds the Lease and which logs apart from op. Each case runs
# the script under `env -i` and compares its whole stderr, both call logs, the kubeconfig and the
# stored Lease, with each Lease time a take writes checked for its form and for falling between the
# clock's readings before and after the act.
#
#   bash scripts/test-hold-deploy-prod-lock.sh
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
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-op-read.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hold-deploy-prod-lock.sh"
# the stored Lease with each time replaced by whether it has a Lease's MicroTime form
masked='.spec |= with_entries(if .key == "acquireTime" or .key == "renewTime" then .value |= test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.000000Z$") else . end)'

it_writes_the_kubeconfig_privately_and_takes_the_lock_as_the_run_for_6000_seconds() {
  local status=0
  create_case_tree
  setup_test "$tree"
  before="$(date -u +%s)"
  mkdir -p "$tree/vault/cloud-deploy/k3s-kubeconfig"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/vault/cloud-deploy/k3s-kubeconfig/kubeconfig.yaml"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" OP_SERVICE_ACCOUNT_TOKEN=example-op-token \
    bash "$script" take > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'hold-prod-lock: took the prod lock as deploy-prod 18342'
  printf 'apiVersion: v1\nkind: Config\n' | diff - "$tree/runner/kubeconfig"
  stat -c %a "$tree/runner/kubeconfig" > "$tree/mode"
  diff - "$tree/mode" <<< 600
  diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud-deploy/k3s-kubeconfig/kubeconfig.yaml"]'
  after="$(date -u +%s)"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the acquire time"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the renew time"
  jq -c "$masked" "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"1"},"spec":{"holderIdentity":"deploy-prod 18342","leaseDurationSeconds":6000,"acquireTime":true,"renewTime":true}}
EOF
  assert_status 0 "$status"
}

it_takes_back_the_hold_that_an_earlier_attempt_of_the_run_left() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/k3s-kubeconfig"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/vault/cloud-deploy/k3s-kubeconfig/kubeconfig.yaml"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"6"},"spec":{"holderIdentity":"deploy-prod 18342","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" OP_SERVICE_ACCOUNT_TOKEN=example-op-token \
    bash "$script" take > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'hold-prod-lock: took the prod lock as deploy-prod 18342'
  jq -r '"\(.metadata.resourceVersion) \(.spec.holderIdentity)"' "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  diff - "$tree/lease" <<< '7 deploy-prod 18342'
  after="$(date -u +%s)"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the acquire time"
  assert_between "$before" "$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)" "$after" "the renew time"
  assert_status 0 "$status"
}

it_leaves_no_kubeconfig_and_takes_nothing_when_1password_does_not_answer() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" OP_SERVICE_ACCOUNT_TOKEN=example-op-token \
    bash "$script" take > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << 'EOF'
[ERROR] 2026/10/07 12:00:00 could not read secret op://cloud-deploy/k3s-kubeconfig/kubeconfig.yaml: could not get item cloud-deploy/k3s-kubeconfig: "k3s-kubeconfig" isn't an item in the "cloud-deploy" vault.
EOF
  ls -A "$tree/runner" > "$tree/left"
  diff /dev/null "$tree/left"
  diff /dev/null "$tree/kubectl-calls"
  assert_status 1 "$status"
}

it_releases_the_run_s_lock_and_removes_the_kubeconfig() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 18342","leaseDurationSeconds":6000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" \
    bash "$script" release > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'hold-prod-lock: released the prod lock as deploy-prod 18342'
  jq -c .spec "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  diff - "$tree/lease" <<< '{"leaseDurationSeconds":6000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}'
  assert_missing "$tree/runner/kubeconfig" "the kubeconfig was kept"
  diff /dev/null "$tree/calls"
  assert_status 0 "$status"
}

it_does_nothing_on_release_when_the_job_never_wrote_the_kubeconfig() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" \
    bash "$script" release > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< "hold-deploy-prod-lock: no kubeconfig at $tree/runner/kubeconfig, so the job never took the lock"
  diff /dev/null "$tree/kubectl-calls"
  assert_status 0 "$status"
}

it_refuses_to_run_without_its_run_id() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    KUBECONFIG="$tree/runner/kubeconfig" \
    bash "$script" take > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'hold-deploy-prod-lock: set RUN_ID'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

it_rejects_a_second_argument_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" \
    bash "$script" take now > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'usage: hold-deploy-prod-lock.sh take|release'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/runner" "$tree/store/kube-system"
  : > "$tree/calls"
  : > "$tree/kubectl-calls"
  create_stub_op_read "$tree/bin"
  create_stub_kubectl "$tree/bin" "$tree/store" "$tree/kubectl-calls"
}

run_cases
