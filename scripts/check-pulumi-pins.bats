#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for check-pulumi-pins.sh: against package.json files in the case tree, it passes silently
# when infra and the generated SDK pin the same @pulumi/pulumi, and fails with both versions when
# they differ or when either file has no pin. Each case runs the script under `env -i`.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/check-pulumi-pins.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp" "$tree/repo/infra" "$tree/repo/sdk/onidel"
}

@test "it passes silently when the pins match" {
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"3.264.0","@pulumi/tls":"5.6.1"}}' > "$tree/repo/infra/package.json"
  echo '{"dependencies":{"@pulumi/pulumi":"3.264.0"}}' > "$tree/repo/sdk/onidel/package.json"

  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/repo"

  refute_output
  refute_stderr
}

@test "it fails with both versions when the pins differ" {
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"3.264.0"}}' > "$tree/repo/infra/package.json"
  echo '{"dependencies":{"@pulumi/pulumi":"3.251.0"}}' > "$tree/repo/sdk/onidel/package.json"

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/repo"

  refute_output
  assert_stderr - << 'EOF'
@pulumi/pulumi pins differ: infra/package.json has '3.264.0', sdk/onidel/package.json has '3.251.0'
change infra's pin, then run: bun run sdk:gen
EOF
}

@test "it fails when the sdk has no pin" {
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"3.264.0"}}' > "$tree/repo/infra/package.json"
  echo '{"dependencies":{}}' > "$tree/repo/sdk/onidel/package.json"

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/repo"

  refute_output
  assert_stderr - << 'EOF'
@pulumi/pulumi pins differ: infra/package.json has '3.264.0', sdk/onidel/package.json has ''
change infra's pin, then run: bun run sdk:gen
EOF
}

@test "it fails when neither file has a pin" {
  setup_test "$tree"
  echo '{}' > "$tree/repo/infra/package.json"
  echo '{}' > "$tree/repo/sdk/onidel/package.json"

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/repo"

  refute_output
  assert_stderr - << 'EOF'
@pulumi/pulumi pins differ: infra/package.json has '', sdk/onidel/package.json has ''
change infra's pin, then run: bun run sdk:gen
EOF
}
