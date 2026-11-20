#!/usr/bin/env bats
# bats file_tags=suite:scripts
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
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-kubectl.sh'
  load 'src/test-utils/shell/create-stub-scripted-command.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/cancel-deploy-prod-update.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
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

@test "it cancels the prod stack s update in infra while the run holds the prod lock" {
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 18342","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF
  printf "The currently running update for 'prod' has been canceled!\n" > "$tree/op-answers/1.out"

  run -0 --separate-stderr env -C "$tree/runner" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG_ENV=OP_SERVICE_ACCOUNT_TOKEN APPLY_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" \
    PROGRAM=program OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script"

  assert_output "The currently running update for 'prod' has been canceled!"
  assert_stderr 'hold-prod-lock: deploy-prod 18342 holds the prod lock until 2099-01-01T01:40:00.000000Z'

  run -0 diff - "$tree/kubectl-calls" <<< '["kubectl","--request-timeout=30s","--namespace","kube-system","get","lease","cloud-prod-state","--output","json"]'
  run -0 diff - "$tree/op-calls" <<< "{\"cwd\":\"$tree/runner/program/infra\",\"argv\":[\"op\",\"run\",\"--env-file=../.env\",\"--\",\"pulumi\",\"cancel\",\"--stack\",\"prod\",\"--yes\"],\"env\":{\"OP_SERVICE_ACCOUNT_TOKEN\":\"example-op-token\"}}"
}

@test "it exits with pulumi cancel s status when the cancel fails" {
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 18342","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF
  printf 'error: failed to load checkpoint: blob (key ".pulumi/stacks/cloud/prod.json") (code=Unknown): RequestError: send request failed\n' > "$tree/op-answers/1.err"
  echo 255 > "$tree/op-answers/1.status"

  run -255 --separate-stderr env -C "$tree/runner" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    APPLY_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" PROGRAM=program \
    OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script"

  refute_output
  assert_stderr - << 'EOF'
hold-prod-lock: deploy-prod 18342 holds the prod lock until 2099-01-01T01:40:00.000000Z
error: failed to load checkpoint: blob (key ".pulumi/stacks/cloud/prod.json") (code=Unknown): RequestError: send request failed
EOF
}

@test "it cancels nothing while a drift check holds the prod lock" {
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"4"},"spec":{"holderIdentity":"drift-check 0a1b2c3d","leaseDurationSeconds":3000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  run -3 --separate-stderr env -C "$tree/runner" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    APPLY_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" PROGRAM=program \
    OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script"

  refute_output
  assert_stderr - << 'EOF'
hold-prod-lock: deploy-prod 18342 does not hold the prod lock; its holder is drift-check 0a1b2c3d
cancel-deploy-prod-update: the job does not hold the prod lock, so it leaves the Pulumi lock to its holder
EOF

  run -0 diff /dev/null "$tree/op-calls"
}

@test "it cancels the update when the run s lease ran out and no one took the prod lock over" {
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 18342","leaseDurationSeconds":6000,"acquireTime":"2026-03-04T08:21:58.000000Z","renewTime":"2026-03-04T08:21:58.000000Z"}}
EOF
  printf "The currently running update for 'prod' has been canceled!\n" > "$tree/op-answers/1.out"

  run -0 --separate-stderr env -C "$tree/runner" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    REFRESH_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" PROGRAM=program \
    OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script"

  assert_output "The currently running update for 'prod' has been canceled!"
  assert_stderr 'hold-prod-lock: deploy-prod 18342 holds the prod lock; its lease ran out at 2026-03-04T10:01:58.000000Z, and no one took it over'

  run -0 diff - "$tree/op-calls" <<< "{\"cwd\":\"$tree/runner/program/infra\",\"argv\":[\"op\",\"run\",\"--env-file=../.env\",\"--\",\"pulumi\",\"cancel\",\"--stack\",\"prod\",\"--yes\"]}"
}

@test "it cancels nothing and exits 1 with kubectl s error when the api refuses the read" {
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"
  echo 'system:serviceaccount:example-ns:example-account' > "$tree/store/forbidden"

  run -1 --separate-stderr env -C "$tree/runner" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    APPLY_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" PROGRAM=program \
    OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script"

  refute_output
  assert_stderr 'Error from server (Forbidden): leases.coordination.k8s.io "cloud-prod-state" is forbidden: User "system:serviceaccount:example-ns:example-account" cannot get resource "leases" in API group "coordination.k8s.io" in the namespace "kube-system"'

  run -0 diff /dev/null "$tree/op-calls"
}

@test "it cancels nothing when the apply failed and the cancel came after" {
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"

  run -0 --separate-stderr env -C "$tree/runner" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    REFRESH_OUTCOME=success APPLY_OUTCOME=failure RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" \
    PROGRAM=program OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script"

  refute_output
  assert_stderr 'cancel-deploy-prod-update: the cancel stopped neither the refresh nor the apply, so no update of this run holds the Pulumi lock'

  run -0 diff /dev/null "$tree/kubectl-calls"
  run -0 diff /dev/null "$tree/op-calls"
}

@test "it cancels nothing when the cancel came before the refresh" {
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"

  run -0 --separate-stderr env -C "$tree/runner" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    REFRESH_OUTCOME=skipped APPLY_OUTCOME=skipped RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" \
    PROGRAM=program OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script"

  refute_output
  assert_stderr 'cancel-deploy-prod-update: the cancel stopped neither the refresh nor the apply, so no update of this run holds the Pulumi lock'

  run -0 diff /dev/null "$tree/kubectl-calls"
  run -0 diff /dev/null "$tree/op-calls"
}

@test "it does nothing when the job never wrote the kubeconfig" {
  setup_test "$tree"

  run -0 --separate-stderr env -C "$tree/runner" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    APPLY_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" PROGRAM=program \
    OP_SERVICE_ACCOUNT_TOKEN=example-op-token bash "$script"

  refute_output
  assert_stderr "cancel-deploy-prod-update: no kubeconfig at $tree/runner/kubeconfig, so the job never took the prod lock"

  run -0 diff /dev/null "$tree/kubectl-calls"
  run -0 diff /dev/null "$tree/op-calls"
}

@test "it refuses to run without the program checkout" {
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"

  run -2 --separate-stderr env -C "$tree/runner" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    APPLY_OUTCOME=cancelled RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" OP_SERVICE_ACCOUNT_TOKEN=example-op-token \
    bash "$script"

  refute_output
  assert_stderr 'cancel-deploy-prod-update: set PROGRAM'

  run -0 diff /dev/null "$tree/kubectl-calls"
  run -0 diff /dev/null "$tree/op-calls"
}
