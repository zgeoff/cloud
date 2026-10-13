#!/usr/bin/env bash
# Test for check-atc-gateway-skew.sh: it passes a daemon pin and gateway images of the same atc
# major, and refuses a pin a major ahead of a gateway pod or behind it, no gateway pod, a gateway
# image that is no atc-gateway release, an atc.nix with no version line or two, and a missing
# atc.nix. Each case writes its own atc.nix in the case tree and runs the script under `env -i`.
#
#   bash scripts/test-check-atc-gateway-skew.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-atc-gateway-skew.sh"

# setup_test <tree>: the home and temp folders the cases run with
setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp"
}

it_passes_a_daemon_a_minor_release_behind_the_gateway() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "2.26.2";
  sha256 = "4d92b125a68edbd067ea0eaac493790402baa9102229df2843dea962250602e7";
in
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:2.27.0@sha256:b53896a326e7c407167a5973736526b68ca6f30500d00558f1a7350869d91867 \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '== atc 2.26.2 on the host, 2.27.0 in the gateway'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_passes_a_gateway_image_without_a_digest() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "4.5.0";
in
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:4.5.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '== atc 4.5.0 on the host, 4.5.0 in the gateway'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_refuses_a_daemon_a_major_release_ahead_of_the_gateway() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "4.5.0";
  sha256 = "1111111111111111111111111111111111111111111111111111111111111111";
in
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:2.27.0@sha256:b53896a326e7c407167a5973736526b68ca6f30500d00558f1a7350869d91867 \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the switch would run atc 4.5.0 on the host, but an atc gateway pod runs atc 2.27.0, and atc changes its daemon protocol in a major release; deploy an atc-gateway 4.x image first (docs/runbooks/workflows.md, Switch the host)'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_daemon_a_major_release_behind_the_gateway() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "2.26.2";
in
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:4.5.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the switch would run atc 2.26.2 on the host, but an atc gateway pod runs atc 4.5.0, and atc changes its daemon protocol in a major release; deploy an atc-gateway 2.x image first (docs/runbooks/workflows.md, Switch the host)'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_gateway_image_from_another_repository() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "2.26.2";
in
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "an atc gateway pod runs 'ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2', which is no atc-gateway release image"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_an_empty_gateway_image() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "2.26.2";
in
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" '' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "an atc gateway pod runs '', which is no atc-gateway release image"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_an_atc_nix_without_a_version_line() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  sha256 = "4d92b125a68edbd067ea0eaac493790402baa9102229df2843dea962250602e7";
in
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:2.27.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$tree/atc.nix pins no atc release version"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_an_atc_nix_with_two_version_lines() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "2.26.2";
  version = "4.5.0";
in
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:2.27.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$tree/atc.nix pins no atc release version"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_missing_atc_nix() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:2.27.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$tree/atc.nix is missing, so the switch has no atc daemon pin to compare"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# a gateway rollout recreates its one pod, so for a while no gateway pod runs
it_refuses_when_no_gateway_pod_runs() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "4.5.0";
in
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'no atc gateway pod runs, so the switch cannot tell which atc it speaks; wait for its rollout (kubectl -n atc rollout status deployment atc-gateway)'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_passes_every_gateway_pod_of_the_daemon_pins_major() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "4.5.0";
in
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:4.4.0 ghcr.io/zgeoff/atc-gateway:4.5.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '== atc 4.5.0 on the host, 4.4.0 4.5.0 in the gateway'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# an old pod that still runs beside a new one, as a rollout other than Recreate would leave
it_refuses_when_one_gateway_pod_runs_another_major() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/atc.nix" << 'EOF'
let
  version = "4.5.0";
in
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" "$tree/atc.nix" \
    ghcr.io/zgeoff/atc-gateway:4.5.0 ghcr.io/zgeoff/atc-gateway:2.27.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the switch would run atc 4.5.0 on the host, but an atc gateway pod runs atc 2.27.0, and atc changes its daemon protocol in a major release; deploy an atc-gateway 4.x image first (docs/runbooks/workflows.md, Switch the host)'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_prints_its_usage_without_an_atc_nix() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: check-atc-gateway-skew.sh <atc.nix> [<gateway image>...]'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

run_cases
