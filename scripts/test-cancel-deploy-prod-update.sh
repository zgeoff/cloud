#!/usr/bin/env bash
# Test for cancel-deploy-prod-update.sh: after the cancel stopped the refresh or the apply, and
# while the run holds the prod lock, it runs
# `op run --env-file=../.env -- pulumi cancel --stack prod --yes` in the program checkout's infra/
# and passes pulumi's status through, a lease that ran out with no takeover included; it cancels
# nothing and exits 3 when a drift check holds the prod lock, and exits 1 when kubectl fails; it
# does nothing when the cancel stopped neither step or the job never wrote the kubeconfig; and it
# refuses a missing input.
#
# kubectl is create-stub-kubectl.sh, whose store holds the Lease, and op is
# create-stub-scripted-command.sh, which logs each call's working directory, argv and the token it
# receives. Each case runs the script under `env -i` and compares its whole stdout, stderr and both
# call logs.
#
#   bash scripts/test-cancel-deploy-prod-update.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-kubectl.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-scripted-command.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cancel-deploy-prod-update.sh"

it_cancels_the_prod_stack_s_update_in_infra_while_the_run_holds_the_prod_lock() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 18342","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF
  printf "The currently running update for 'prod' has been canceled!\n" > "$tree/op-answers/1.out"

  (cd "$tree/runner" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG_ENV=OP_SERVICE_ACCOUNT_TOKEN APPLY_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" \
    PROGRAM=program OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script") \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "The currently running update for 'prod' has been canceled!"
  diff - "$tree/err" <<< 'hold-prod-lock: deploy-prod 18342 holds the prod lock until 2099-01-01T01:40:00.000000Z'
  diff - "$tree/kubectl-calls" <<< '["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]'
  diff - "$tree/op-calls" <<< "{\"cwd\":\"$tree/runner/program/infra\",\"argv\":[\"op\",\"run\",\"--env-file=../.env\",\"--\",\"pulumi\",\"cancel\",\"--stack\",\"prod\",\"--yes\"],\"env\":{\"OP_SERVICE_ACCOUNT_TOKEN\":\"example-op-token\"}}"
  assert_status 0 "$status"
}

it_exits_with_pulumi_cancel_s_status_when_the_cancel_fails() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 18342","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF
  printf 'error: failed to load checkpoint: blob (key ".pulumi/stacks/cloud/prod.json") (code=Unknown): RequestError: send request failed\n' > "$tree/op-answers/1.err"
  echo 255 > "$tree/op-answers/1.status"

  (cd "$tree/runner" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    APPLY_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" PROGRAM=program \
    OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
hold-prod-lock: deploy-prod 18342 holds the prod lock until 2099-01-01T01:40:00.000000Z
error: failed to load checkpoint: blob (key ".pulumi/stacks/cloud/prod.json") (code=Unknown): RequestError: send request failed
EOF
  assert_status 255 "$status"
}

it_cancels_nothing_while_a_drift_check_holds_the_prod_lock() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"4"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  (cd "$tree/runner" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    APPLY_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" PROGRAM=program \
    OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
hold-prod-lock: deploy-prod 18342 does not hold the prod lock; its holder is drift-check 0a1b2c3d
cancel-deploy-prod-update: the job does not hold the prod lock, so it leaves the Pulumi lock to its holder
EOF
  diff /dev/null "$tree/op-calls"
  assert_status 3 "$status"
}

it_cancels_the_update_when_the_run_s_lease_ran_out_and_no_one_took_the_prod_lock_over() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 18342","leaseDurationSeconds":6000,"acquireTime":"2026-03-04T08:21:58.000000Z","renewTime":"2026-03-04T08:21:58.000000Z"}}
EOF
  printf "The currently running update for 'prod' has been canceled!\n" > "$tree/op-answers/1.out"

  (cd "$tree/runner" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    REFRESH_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" PROGRAM=program \
    OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "The currently running update for 'prod' has been canceled!"
  diff - "$tree/err" <<< 'hold-prod-lock: deploy-prod 18342 holds the prod lock; its lease ran out at 2026-03-04T10:01:58.000000Z, and no one took it over'
  diff - "$tree/op-calls" <<< "{\"cwd\":\"$tree/runner/program/infra\",\"argv\":[\"op\",\"run\",\"--env-file=../.env\",\"--\",\"pulumi\",\"cancel\",\"--stack\",\"prod\",\"--yes\"]}"
  assert_status 0 "$status"
}

it_cancels_nothing_and_exits_1_with_kubectl_s_error_when_the_api_refuses_the_read() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"
  echo 'system:serviceaccount:example-ns:example-account' > "$tree/store/forbidden"

  (cd "$tree/runner" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    APPLY_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" PROGRAM=program \
    OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error from server (Forbidden): leases.coordination.k8s.io "cloud-prod-state" is forbidden: User "system:serviceaccount:example-ns:example-account" cannot get resource "leases" in API group "coordination.k8s.io" in the namespace "kube-system"'
  diff /dev/null "$tree/op-calls"
  assert_status 1 "$status"
}

it_cancels_nothing_when_the_apply_failed_and_the_cancel_came_after() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"

  (cd "$tree/runner" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    REFRESH_OUTCOME=success APPLY_OUTCOME=failure RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" \
    PROGRAM=program OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script") \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'cancel-deploy-prod-update: the cancel stopped neither the refresh nor the apply, so no update of this run holds the Pulumi lock'
  diff /dev/null "$tree/kubectl-calls"
  diff /dev/null "$tree/op-calls"
  assert_status 0 "$status"
}

it_cancels_nothing_when_the_cancel_came_before_the_refresh() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"

  (cd "$tree/runner" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    REFRESH_OUTCOME=skipped APPLY_OUTCOME=skipped RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" \
    PROGRAM=program OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script") \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'cancel-deploy-prod-update: the cancel stopped neither the refresh nor the apply, so no update of this run holds the Pulumi lock'
  diff /dev/null "$tree/kubectl-calls"
  diff /dev/null "$tree/op-calls"
  assert_status 0 "$status"
}

it_does_nothing_when_the_job_never_wrote_the_kubeconfig() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/runner" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    APPLY_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" PROGRAM=program \
    OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "cancel-deploy-prod-update: no kubeconfig at $tree/runner/kubeconfig, so the job never took the prod lock"
  diff /dev/null "$tree/kubectl-calls"
  diff /dev/null "$tree/op-calls"
  assert_status 0 "$status"
}

it_refuses_to_run_without_the_program_checkout() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"

  (cd "$tree/runner" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    APPLY_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" OP_SERVICE_ACCOUNT_TOKEN=example-op-token \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'cancel-deploy-prod-update: set PROGRAM'
  diff /dev/null "$tree/kubectl-calls"
  diff /dev/null "$tree/op-calls"
  assert_status 2 "$status"
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/runner/program/infra" \
    "$tree/store/kube-system" "$tree/op-answers"
  : > "$tree/kubectl-calls"
  : > "$tree/op-calls"
  create_stub_kubectl "$tree/bin" "$tree/store" "$tree/kubectl-calls"
  create_stub_scripted_command "$tree/bin" op "$tree/op-calls" "$tree/op-answers"
}

run_cases
