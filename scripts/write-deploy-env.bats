#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for write-deploy-env.sh: on a real env file in the case tree, it rewrites each reference
# to the cloud vault to the cloud-deploy vault and keeps comments, blank lines and plain values,
# refuses a reference to another vault or in another form and leaves the file unchanged, and
# rejects a missing argument. Each case runs the script under `env -i`.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/write-deploy-env.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp" "$tree/work"
}

@test "it rewrites each cloud reference to the deploy vault" {
  setup_test "$tree"
  cat > "$tree/work/.env" << 'EOF'
# Every value is an op:// reference resolved by `op run --env-file=.env -- <command>`.

# Onidel provider
ONIDEL_API_KEY=op://cloud/onidel-api/credential
AWS_REGION=auto
K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml
EOF

  run -0 --separate-stderr env -C "$tree/work" -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" .env

  refute_output
  refute_stderr

  run -0 diff - "$tree/work/.env" << 'EOF'
# Every value is an op:// reference resolved by `op run --env-file=.env -- <command>`.

# Onidel provider
ONIDEL_API_KEY=op://cloud-deploy/onidel-api/credential
AWS_REGION=auto
K3S_KUBECONFIG=op://cloud-deploy/k3s-kubeconfig/kubeconfig.yaml
EOF
  run -0 diff <(echo .env) <(ls -A "$tree/work")
}

@test "it refuses a reference to another vault and leaves the file unchanged" {
  setup_test "$tree"
  cat > "$tree/work/.env" << 'EOF'
ONIDEL_API_KEY=op://cloud/onidel-api/credential
E2E_CLIENT_SECRET=op://imp-e2e/tailscale-oauth/client-secret
QUOTED_TOKEN="op://cloud/alert-webhook/credential"
EOF
  cp "$tree/work/.env" "$tree/before"

  run -1 --separate-stderr env -C "$tree/work" -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" .env

  refute_output
  assert_stderr 'write-deploy-env: a reference outside the cloud vault: E2E_CLIENT_SECRET QUOTED_TOKEN'

  run -0 diff "$tree/before" "$tree/work/.env"
}

@test "it rejects a missing argument with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/work" -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script"

  refute_output
  assert_stderr 'usage: write-deploy-env.sh <env file>'
}
