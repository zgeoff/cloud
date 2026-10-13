#!/usr/bin/env bash
# Test for write-deploy-env.sh: on a real env file in the case tree, it rewrites each reference
# to the cloud vault to the cloud-deploy vault and keeps comments, blank lines and plain values,
# refuses a reference to another vault or in another form and leaves the file unchanged, and
# rejects a missing argument. Each case runs the script under `env -i`.
#
#   bash scripts/test-write-deploy-env.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/write-deploy-env.sh"

it_rewrites_each_cloud_reference_to_the_deploy_vault() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/work/.env" << 'EOF'
# Every value is an op:// reference resolved by `op run --env-file=.env -- <command>`.

# Onidel provider
ONIDEL_API_KEY=op://cloud/onidel-api/credential
AWS_REGION=auto
K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml
EOF

  (cd "$tree/work" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" .env) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/work/.env" << 'EOF'
# Every value is an op:// reference resolved by `op run --env-file=.env -- <command>`.

# Onidel provider
ONIDEL_API_KEY=op://cloud-deploy/onidel-api/credential
AWS_REGION=auto
K3S_KUBECONFIG=op://cloud-deploy/k3s-kubeconfig/kubeconfig.yaml
EOF
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff <(echo .env) <(ls -A "$tree/work")
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_refuses_a_reference_to_another_vault_and_leaves_the_file_unchanged() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/work/.env" << 'EOF'
ONIDEL_API_KEY=op://cloud/onidel-api/credential
E2E_CLIENT_SECRET=op://imp-e2e/tailscale-oauth/client-secret
QUOTED_TOKEN="op://cloud/alert-webhook/credential"
EOF
  cp "$tree/work/.env" "$tree/before"

  (cd "$tree/work" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" .env) > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/before" "$tree/work/.env"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'write-deploy-env: a reference outside the cloud vault: E2E_CLIENT_SECRET QUOTED_TOKEN'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_missing_argument_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/work" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: write-deploy-env.sh <env file>'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp" "$tree/work"
}

run_cases
