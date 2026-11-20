#!/usr/bin/env bats
# bats file_tags=suite:scripts
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
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-kubectl.sh'
  load 'src/test-utils/shell/create-stub-op-read.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/hold-deploy-prod-lock.sh"
  # the stored Lease with each time replaced by whether it has a Lease's MicroTime form
  masked='.spec |= with_entries(if .key == "acquireTime" or .key == "renewTime" then .value |= test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.000000Z$") else . end)'
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/runner" "$tree/store/kube-system"
  : > "$tree/calls"
  : > "$tree/kubectl-calls"
  create_stub_op_read "$tree/bin"
  create_stub_kubectl "$tree/bin" "$tree/store" "$tree/kubectl-calls"
}

@test "it writes the kubeconfig privately and takes the lock as the run for 6000 seconds" {
  setup_test "$tree"
  before="$(date -u +%s)"
  mkdir -p "$tree/vault/cloud-deploy/k3s-kubeconfig"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/vault/cloud-deploy/k3s-kubeconfig/kubeconfig.yaml"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" OP_SERVICE_ACCOUNT_TOKEN=example-op-token \
    bash "$script" take

  refute_output
  assert_stderr 'hold-prod-lock: took the prod lock as deploy-prod 18342'

  run -0 diff <(printf 'apiVersion: v1\nkind: Config\n') "$tree/runner/kubeconfig"
  stat -c %a "$tree/runner/kubeconfig" > "$tree/mode"
  run -0 diff - "$tree/mode" <<< 600
  run -0 diff - "$tree/calls" <<< '["op","read","--no-newline","op://cloud-deploy/k3s-kubeconfig/kubeconfig.yaml"]'
  after="$(date -u +%s)"
  actual="$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
  actual="$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
  jq -c "$masked" "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  run -0 diff - "$tree/lease" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"1"},"spec":{"holderIdentity":"deploy-prod 18342","leaseDurationSeconds":6000,"acquireTime":true,"renewTime":true}}
EOF
}

@test "it takes back the hold that an earlier attempt of the run left" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy/k3s-kubeconfig"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/vault/cloud-deploy/k3s-kubeconfig/kubeconfig.yaml"
  before="$(date -u +%s)"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"6"},"spec":{"holderIdentity":"deploy-prod 18342","leaseDurationSeconds":6000,"acquireTime":"2099-01-01T00:00:00.000000Z","renewTime":"2099-01-01T00:00:00.000000Z"}}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" OP_SERVICE_ACCOUNT_TOKEN=example-op-token \
    bash "$script" take

  assert_stderr 'hold-prod-lock: took the prod lock as deploy-prod 18342'

  jq -r '"\(.metadata.resourceVersion) \(.spec.holderIdentity)"' "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  run -0 diff - "$tree/lease" <<< '7 deploy-prod 18342'
  after="$(date -u +%s)"
  actual="$(date -u -d "$(jq -r .spec.acquireTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
  actual="$(date -u -d "$(jq -r .spec.renewTime "$tree/store/kube-system/cloud-prod-state.json")" +%s)"
  assert [ "$actual" -ge "$before" ]
  assert [ "$actual" -le "$after" ]
}

@test "it leaves no kubeconfig and takes nothing when 1password does not answer" {
  setup_test "$tree"
  mkdir -p "$tree/vault/cloud-deploy"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" OP_SERVICE_ACCOUNT_TOKEN=example-op-token \
    bash "$script" take

  assert_stderr - << 'EOF'
[ERROR] 2026/10/07 12:00:00 could not read secret op://cloud-deploy/k3s-kubeconfig/kubeconfig.yaml: could not get item cloud-deploy/k3s-kubeconfig: "k3s-kubeconfig" isn't an item in the "cloud-deploy" vault.
EOF

  ls -A "$tree/runner" > "$tree/left"
  run -0 diff /dev/null "$tree/left"
  run -0 diff /dev/null "$tree/kubectl-calls"
}

@test "it releases the run s lock and removes the kubeconfig" {
  setup_test "$tree"
  printf 'apiVersion: v1\nkind: Config\n' > "$tree/runner/kubeconfig"
  cat > "$tree/store/kube-system/cloud-prod-state.json" << 'EOF'
{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"kube-system","name":"cloud-prod-state","resourceVersion":"2"},"spec":{"holderIdentity":"deploy-prod 18342","leaseDurationSeconds":6000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" \
    bash "$script" release

  assert_stderr 'hold-prod-lock: released the prod lock as deploy-prod 18342'

  jq -c .spec "$tree/store/kube-system/cloud-prod-state.json" > "$tree/lease"
  run -0 diff - "$tree/lease" <<< '{"leaseDurationSeconds":6000,"acquireTime":"2026-10-21T05:41:00.000000Z","renewTime":"2026-10-21T05:41:00.000000Z"}'
  refute [ -e "$tree/runner/kubeconfig" ]
  refute [ -L "$tree/runner/kubeconfig" ]
  run -0 diff /dev/null "$tree/calls"
}

@test "it does nothing on release when the job never wrote the kubeconfig" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" \
    bash "$script" release

  assert_stderr "hold-deploy-prod-lock: no kubeconfig at $tree/runner/kubeconfig, so the job never took the lock"

  run -0 diff /dev/null "$tree/kubectl-calls"
}

@test "it refuses to run without its run id" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    KUBECONFIG="$tree/runner/kubeconfig" \
    bash "$script" take

  assert_stderr 'hold-deploy-prod-lock: set RUN_ID'

  run -0 diff /dev/null "$tree/calls"
}

@test "it rejects a second argument with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    RUN_ID=18342 KUBECONFIG="$tree/runner/kubeconfig" \
    bash "$script" take now

  assert_stderr 'usage: hold-deploy-prod-lock.sh take|release'

  run -0 diff /dev/null "$tree/calls"
}
