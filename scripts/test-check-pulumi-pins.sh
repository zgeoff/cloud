#!/usr/bin/env bash
# Test for check-pulumi-pins.sh: against package.json files in the case tree, it passes silently
# when infra and the generated SDK pin the same @pulumi/pulumi, and fails with both versions when
# they differ or when either file has no pin. Each case runs the script under `env -i`.
#
#   bash scripts/test-check-pulumi-pins.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-pulumi-pins.sh"

it_passes_silently_when_the_pins_match() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"3.264.0","@pulumi/tls":"5.6.1"}}' > "$tree/repo/infra/package.json"
  echo '{"dependencies":{"@pulumi/pulumi":"3.264.0"}}' > "$tree/repo/sdk/onidel/package.json"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/repo" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_with_both_versions_when_the_pins_differ() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"3.264.0"}}' > "$tree/repo/infra/package.json"
  echo '{"dependencies":{"@pulumi/pulumi":"3.251.0"}}' > "$tree/repo/sdk/onidel/package.json"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/repo" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
@pulumi/pulumi pins differ: infra/package.json has '3.264.0', sdk/onidel/package.json has '3.251.0'
change infra's pin, then run: bun run sdk:gen
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_when_the_sdk_has_no_pin() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"3.264.0"}}' > "$tree/repo/infra/package.json"
  echo '{"dependencies":{}}' > "$tree/repo/sdk/onidel/package.json"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/repo" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
@pulumi/pulumi pins differ: infra/package.json has '3.264.0', sdk/onidel/package.json has ''
change infra's pin, then run: bun run sdk:gen
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_when_neither_file_has_a_pin() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{}' > "$tree/repo/infra/package.json"
  echo '{}' > "$tree/repo/sdk/onidel/package.json"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/repo" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
@pulumi/pulumi pins differ: infra/package.json has '', sdk/onidel/package.json has ''
change infra's pin, then run: bun run sdk:gen
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp" "$tree/repo/infra" "$tree/repo/sdk/onidel"
}

run_cases
