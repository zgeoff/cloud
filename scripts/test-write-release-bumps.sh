#!/usr/bin/env bash
# Test for write-release-bumps.sh: from a checkout's pins and the releases that the gh stand-in
# (test-support/shell/create-stub-release-gh.sh) lists, it writes find-release-bumps.sh's lines as
# the multiline `bumps` output and lists them on stdout and in the step summary; when every pin is
# current it says so and writes no output; and a failed search fails it with that error, writing
# nothing. Each case runs the script under `env -i` from the checkout and compares its whole
# stdout, stderr, GITHUB_OUTPUT and step summary.
#
#   bash scripts/test-write-release-bumps.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/../test-support/shell/run-cases.sh"
source "$scripts/../test-support/shell/create-stub-release-gh.sh"

script="$scripts/write-release-bumps.sh"

it_writes_each_bump_as_the_bumps_output_and_lists_them() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222
ARG ATC_VERSION=4.3.0
ARG AUTO_MODE_VERSION=0.19.3
EOF
  echo '  version = "4.2.0";' > "$tree/seed/nixos/packages/atc.nix"
  echo 'ATC_RELEASE=@zgeoff/atc@4.3.0' > "$tree/seed/images/atc-gateway/versions.env"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/seed/nixos/hosts/geoffcloud/configuration.nix"
  cat > "$tree/seed/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:3333333333333333333333333333333333333333333333333333333333333333
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  echo '@zgeoff/atc@4.3.0' > "$tree/releases/atc/tags"
  echo 'v1.0.1' > "$tree/releases/imp/tags"
  echo 'v0.7.0' > "$tree/releases/nixie/tags"
  echo 'auto-mode-v0.19.3' > "$tree/releases/auto-mode/tags"

  (cd "$tree/seed" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
Pins older than their newest release (dependency, newest, pinned):

- atc 4.3.0 4.3.0 4.2.0 4.3.0
- imp 1.0.1 1.0.0 1.0.0
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/output" << 'OUTPUT'
bumps<<EOF
atc 4.3.0 4.3.0 4.2.0 4.3.0
imp 1.0.1 1.0.0 1.0.0
EOF
OUTPUT
  diff - "$tree/summary" << 'EOF'
Pins older than their newest release (dependency, newest, pinned):

- atc 4.3.0 4.3.0 4.2.0 4.3.0
- imp 1.0.1 1.0.0 1.0.0
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_says_every_pin_is_current_and_writes_no_output() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:2222222222222222222222222222222222222222222222222222222222222222
ARG ATC_VERSION=4.3.0
ARG AUTO_MODE_VERSION=0.19.3
EOF
  echo '  version = "4.3.0";' > "$tree/seed/nixos/packages/atc.nix"
  echo 'ATC_RELEASE=@zgeoff/atc@4.3.0' > "$tree/seed/images/atc-gateway/versions.env"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/seed/nixos/hosts/geoffcloud/configuration.nix"
  cat > "$tree/seed/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:3333333333333333333333333333333333333333333333333333333333333333
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  echo '@zgeoff/atc@4.3.0' > "$tree/releases/atc/tags"
  echo 'v1.0.1' > "$tree/releases/imp/tags"
  echo 'v0.7.0' > "$tree/releases/nixie/tags"
  echo 'auto-mode-v0.19.3' > "$tree/releases/auto-mode/tags"

  (cd "$tree/seed" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'Every pin holds its newest release.'
  diff /dev/null "$tree/err"
  diff /dev/null "$tree/output"
  diff - "$tree/summary" <<< 'Every pin holds its newest release.'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_with_the_search_error_and_writes_nothing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:2222222222222222222222222222222222222222222222222222222222222222
ARG ATC_VERSION=4.3.0
ARG AUTO_MODE_VERSION=0.19.3
EOF
  echo '  version = "4.3.0";' > "$tree/seed/nixos/packages/atc.nix"
  echo 'ATC_RELEASE=@zgeoff/atc@4.3.0' > "$tree/seed/images/atc-gateway/versions.env"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/seed/nixos/hosts/geoffcloud/configuration.nix"
  cat > "$tree/seed/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:3333333333333333333333333333333333333333333333333333333333333333
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF

  (cd "$tree/seed" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'zgeoff/atc has no release tagged @zgeoff/atc@X.Y.Z'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_without_a_step_summary_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/seed" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" GITHUB_OUTPUT="$tree/output" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$script: line 12: GITHUB_STEP_SUMMARY: parameter null or not set"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

# setup_test <tree>: the gh stand-in in <tree>/bin, the home and temp folders the cases run with,
# the empty files the workflow's runner provides, and <tree>/seed, the empty checkout whose pins
# each case writes.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/seed/images/agent" "$tree/seed/nixos/packages" \
    "$tree/seed/nixos/hosts/geoffcloud" "$tree/seed/images/atc-gateway" "$tree/seed/infra" \
    "$tree/releases/atc" "$tree/releases/imp" "$tree/releases/nixie" "$tree/releases/auto-mode"
  : > "$tree/calls"
  # boot data: the runner creates both files before a step runs
  : > "$tree/output"
  : > "$tree/summary"
  create_stub_release_gh "$tree/bin"
}

run_cases
