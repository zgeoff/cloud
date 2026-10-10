#!/usr/bin/env bash
# Test for pin-agent-atc.sh: in a case tree that holds images/agent/Dockerfile, it changes the
# ATC_VERSION and ATC_SHA256 pins to a release's version and its atc-linux-x64 sum from that
# release's SHA256SUMS, and nothing else. It leaves a pin that already matches alone, and refuses
# a sum that differs for the pinned version, a SHA256SUMS without exactly one well-formed
# atc-linux-x64 line, a Dockerfile without exactly one of each pin, and a bad version. Each case
# runs the script under `env -i` from the case tree's repository.
#
#   bash scripts/test-pin-agent-atc.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pin-agent-atc.sh"

# setup_test <tree>: the repository folder the script runs in, with images/agent and no
# Dockerfile, and the home and temp folders the script runs with
setup_test() {
  local tree="$1"
  mkdir -p "$tree/repo/images/agent" "$tree/home" "$tree/tmp"
}

it_pins_a_new_version_and_its_sum() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:0.33.0
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
RUN echo "${ATC_SHA256}  /usr/local/bin/atc" | sha256sum -c -
ARG CODEX_VERSION=0.160.1
EOF
  cat > "$tree/SHA256SUMS" << 'EOF'
1111111111111111111111111111111111111111111111111111111111111111  atc-darwin-arm64
2222222222222222222222222222222222222222222222222222222222222222  atc-gateway-linux-x64
3333333333333333333333333333333333333333333333333333333333333333  atc-linux-arm64
4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64
EOF

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 3.11.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/repo/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:0.33.0
ARG ATC_VERSION=3.11.0
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
RUN echo "${ATC_SHA256}  /usr/local/bin/atc" | sha256sum -c -
ARG CODEX_VERSION=0.160.1
EOF
  diff - "$tree/out" <<< 'pinned atc 3.11.0: 4444444444444444444444444444444444444444444444444444444444444444'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_leaves_a_pin_that_already_matches_alone() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
EOF
  cp -p "$tree/repo/images/agent/Dockerfile" "$tree/before"
  echo '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 3.10.2 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff - "$tree/out" <<< 'atc 3.10.2 is already pinned'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_leaves_a_newer_pin_alone() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.10
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
EOF
  cp -p "$tree/repo/images/agent/Dockerfile" "$tree/before"
  echo '5555555555555555555555555555555555555555555555555555555555555555  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 3.10.9 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff - "$tree/out" <<< 'atc 3.10.10 is pinned, which is newer than 3.10.9'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_refuses_another_sum_for_the_pinned_version() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
EOF
  cp -p "$tree/repo/images/agent/Dockerfile" "$tree/before"
  echo '5555555555555555555555555555555555555555555555555555555555555555  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 3.10.2 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'atc 3.10.2 is pinned with sum 4444444444444444444444444444444444444444444444444444444444444444, but SHA256SUMS lists 5555555555555555555555555555555555555555555555555555555555555555'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_sha256sums_without_an_atc_linux_x64_line() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
EOF
  cp -p "$tree/repo/images/agent/Dockerfile" "$tree/before"
  echo '3333333333333333333333333333333333333333333333333333333333333333  atc-linux-arm64' > "$tree/SHA256SUMS"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 3.11.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'SHA256SUMS has 0 atc-linux-x64 lines, want 1'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_sha256sums_with_two_atc_linux_x64_lines() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
EOF
  cp -p "$tree/repo/images/agent/Dockerfile" "$tree/before"
  cat > "$tree/SHA256SUMS" << 'EOF'
5555555555555555555555555555555555555555555555555555555555555555  atc-linux-x64
6666666666666666666666666666666666666666666666666666666666666666  atc-linux-x64
EOF

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 3.11.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'SHA256SUMS has 2 atc-linux-x64 lines, want 1'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_an_atc_linux_x64_line_that_holds_no_sha256() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
EOF
  cp -p "$tree/repo/images/agent/Dockerfile" "$tree/before"
  echo '555555555555555555555555555555555555555555555555555555555555555G  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 3.11.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "SHA256SUMS's atc-linux-x64 line holds no sha256 sum"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_dockerfile_without_an_atc_version_pin() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444' > "$tree/repo/images/agent/Dockerfile"
  cp -p "$tree/repo/images/agent/Dockerfile" "$tree/before"
  echo '5555555555555555555555555555555555555555555555555555555555555555  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 3.11.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'images/agent/Dockerfile has 0 ARG ATC_VERSION= lines, want 1'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_dockerfile_with_two_atc_sha256_pins() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
EOF
  cp -p "$tree/repo/images/agent/Dockerfile" "$tree/before"
  echo '5555555555555555555555555555555555555555555555555555555555555555  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 3.11.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'images/agent/Dockerfile has 2 ARG ATC_SHA256= lines, want 1'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_folder_without_the_agent_dockerfile() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '5555555555555555555555555555555555555555555555555555555555555555  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 3.11.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'images/agent/Dockerfile is missing: run this from the root of a zgeoff/cloud checkout'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_version_that_is_not_a_release_version() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'ARG ATC_VERSION=3.10.2' > "$tree/repo/images/agent/Dockerfile"
  echo '5555555555555555555555555555555555555555555555555555555555555555  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" '3.11.0/x' "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "not a release version: '3.11.0/x'"
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_prints_its_usage_without_a_sha256sums_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 3.11.0) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: pin-agent-atc.sh <version> <SHA256SUMS file>'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

run_cases
