#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for check-atc-gateway-skew.sh: it passes a daemon pin and gateway images of the same atc
# major, and refuses a pin a major ahead of a gateway pod or behind it, no gateway pod, a gateway
# image that is no atc-gateway release, an atc.nix with no version line or two, and a missing
# atc.nix. Each case writes its own atc.nix in the case tree and runs the script under `env -i`.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/check-atc-gateway-skew.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# setup_test <tree>: the home and temp folders the cases run with
setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp"
}

@test "it passes a daemon a minor release behind the gateway" {
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "2.26.2";
  sha256 = "4d92b125a68edbd067ea0eaac493790402baa9102229df2843dea962250602e7";
in
EOF

  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:2.27.0@sha256:b53896a326e7c407167a5973736526b68ca6f30500d00558f1a7350869d91867

  assert_output '== atc 2.26.2 on the host, 2.27.0 in the gateway'
  refute_stderr
}

@test "it passes a gateway image without a digest" {
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "4.5.0";
in
EOF

  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:4.5.0

  assert_output '== atc 4.5.0 on the host, 4.5.0 in the gateway'
  refute_stderr
}

@test "it refuses a daemon a major release ahead of the gateway" {
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "4.5.0";
  sha256 = "1111111111111111111111111111111111111111111111111111111111111111";
in
EOF

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:2.27.0@sha256:b53896a326e7c407167a5973736526b68ca6f30500d00558f1a7350869d91867

  refute_output
  assert_stderr 'the switch would run atc 4.5.0 on the host, but an atc gateway pod runs atc 2.27.0, and atc changes its daemon protocol in a major release; deploy an atc-gateway 4.x image first (docs/runbooks/workflows.md, Switch the host)'
}

@test "it refuses a daemon a major release behind the gateway" {
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "2.26.2";
in
EOF

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:4.5.0

  refute_output
  assert_stderr 'the switch would run atc 2.26.2 on the host, but an atc gateway pod runs atc 4.5.0, and atc changes its daemon protocol in a major release; deploy an atc-gateway 2.x image first (docs/runbooks/workflows.md, Switch the host)'
}

@test "it refuses a gateway image from another repository" {
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "2.26.2";
in
EOF

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2

  refute_output
  assert_stderr "an atc gateway pod runs 'ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2', which is no atc-gateway release image"
}

@test "it refuses an empty gateway image" {
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "2.26.2";
in
EOF

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" ''

  refute_output
  assert_stderr "an atc gateway pod runs '', which is no atc-gateway release image"
}

@test "it refuses an atc nix without a version line" {
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  sha256 = "4d92b125a68edbd067ea0eaac493790402baa9102229df2843dea962250602e7";
in
EOF

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:2.27.0

  refute_output
  assert_stderr "$tree/atc.nix pins no atc release version"
}

@test "it refuses an atc nix with two version lines" {
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "2.26.2";
  version = "4.5.0";
in
EOF

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:2.27.0

  refute_output
  assert_stderr "$tree/atc.nix pins no atc release version"
}

@test "it refuses a missing atc nix" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:2.27.0

  refute_output
  assert_stderr "$tree/atc.nix is missing, so the switch has no atc daemon pin to compare"
}

# a gateway rollout recreates its one pod, so for a while no gateway pod runs
@test "it refuses when no gateway pod runs" {
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "4.5.0";
in
EOF

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix"

  refute_output
  assert_stderr 'no atc gateway pod runs, so the switch cannot tell which atc it speaks; wait for its rollout (kubectl -n atc rollout status deployment atc-gateway)'
}

@test "it passes every gateway pod of the daemon pins major" {
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "4.5.0";
in
EOF

  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:4.4.0 ghcr.io/zgeoff/atc-gateway:4.5.0

  assert_output '== atc 4.5.0 on the host, 4.4.0 4.5.0 in the gateway'
  refute_stderr
}

# an old pod that still runs beside a new one, as a rollout other than Recreate would leave
@test "it refuses when one gateway pod runs another major" {
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "4.5.0";
in
EOF

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:4.5.0 ghcr.io/zgeoff/atc-gateway:2.27.0

  refute_output
  assert_stderr 'the switch would run atc 4.5.0 on the host, but an atc gateway pod runs atc 2.27.0, and atc changes its daemon protocol in a major release; deploy an atc-gateway 4.x image first (docs/runbooks/workflows.md, Switch the host)'
}

@test "it prints its usage without an atc nix" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script"

  refute_output
  assert_stderr 'usage: check-atc-gateway-skew.sh <atc.nix> [<gateway image>...]'
}
