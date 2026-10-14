#!/usr/bin/env bash
# Test for pin-atc.sh: in a case tree that holds the agent image's Dockerfile, the host daemon's
# nixos/packages/atc.nix and the gateway's deploy/atc-gateway/versions.env, it pins a release in
# all three from that release's SHA256SUMS: atc-linux-x64's sum for the Dockerfile and atc.nix,
# versions.env's ATC_ASSET sum for the gateway, with GATEWAY_IMAGE_TAG moving with the release. It
# keeps a pin that already holds the release or a newer one, and refuses, with no file changed, a
# pin that holds the release with another sum, a SHA256SUMS without the gateway asset, a file
# without exactly one of each pin, and a bad version. Each case runs the script under `env -i`
# from the case tree's repository; the script runs pin-agent-atc.sh from its own directory.
#
#   bash scripts/test-pin-atc.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pin-atc.sh"

# setup_test <tree>: the repository folder the script runs in, with the folders of the three pin
# files and none of the files, and the home and temp folders the script runs with
setup_test() {
  local tree="$1"
  mkdir -p "$tree/repo/images/agent" "$tree/repo/nixos/packages" "$tree/repo/deploy/atc-gateway" \
    "$tree/home" "$tree/tmp"
}

it_pins_the_release_in_all_three_files() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:0.33.0
ARG ATC_VERSION=4.2.0
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  cat > "$tree/repo/nixos/packages/atc.nix" << 'EOF'
let
  version = "2.26.2";
  # the release's SHA256SUMS line for atc-linux-x64
  sha256 = "4d92b125a68edbd067ea0eaac493790402baa9102229df2843dea962250602e7";
in
{ inherit version sha256; }
EOF
  cat > "$tree/repo/deploy/atc-gateway/versions.env" << 'EOF'
ATC_RELEASE=@zgeoff/atc@2.27.0
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=b6f3e54077e05bce6db35e12807eecebf4ac3ee988a7ca4abadb48d8fd602e6d
GATEWAY_IMAGE_TAG=2.27.0
BACKUP_IMAGE_TAG=2.24.0-r2
EOF
  cat > "$tree/SHA256SUMS" << 'EOF'
1111111111111111111111111111111111111111111111111111111111111111  atc-darwin-arm64
2222222222222222222222222222222222222222222222222222222222222222  atc-gateway-linux-x64
3333333333333333333333333333333333333333333333333333333333333333  atc-linux-arm64
4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64
EOF

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 4.3.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/repo/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:0.33.0
ARG ATC_VERSION=4.3.0
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
EOF
  diff - "$tree/repo/nixos/packages/atc.nix" << 'EOF'
let
  version = "4.3.0";
  # the release's SHA256SUMS line for atc-linux-x64
  sha256 = "4444444444444444444444444444444444444444444444444444444444444444";
in
{ inherit version sha256; }
EOF
  diff - "$tree/repo/deploy/atc-gateway/versions.env" << 'EOF'
ATC_RELEASE=@zgeoff/atc@4.3.0
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=2222222222222222222222222222222222222222222222222222222222222222
GATEWAY_IMAGE_TAG=4.3.0
BACKUP_IMAGE_TAG=2.24.0-r2
EOF
  diff - "$tree/out" << 'EOF'
pinned atc 4.3.0: 4444444444444444444444444444444444444444444444444444444444444444
pinned atc 4.3.0 in nixos/packages/atc.nix: 4444444444444444444444444444444444444444444444444444444444444444
pinned atc 4.3.0 in deploy/atc-gateway/versions.env: 2222222222222222222222222222222222222222222222222222222222222222
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_keeps_a_newer_pin_and_pins_the_other_files() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=4.4.0
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  cp -p "$tree/repo/images/agent/Dockerfile" "$tree/before"
  cat > "$tree/repo/nixos/packages/atc.nix" << 'EOF'
  version = "2.26.2";
  sha256 = "4d92b125a68edbd067ea0eaac493790402baa9102229df2843dea962250602e7";
EOF
  cat > "$tree/repo/deploy/atc-gateway/versions.env" << 'EOF'
ATC_RELEASE=@zgeoff/atc@2.27.0
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=b6f3e54077e05bce6db35e12807eecebf4ac3ee988a7ca4abadb48d8fd602e6d
GATEWAY_IMAGE_TAG=2.27.0
EOF
  cat > "$tree/SHA256SUMS" << 'EOF'
2222222222222222222222222222222222222222222222222222222222222222  atc-gateway-linux-x64
4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64
EOF

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 4.3.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff - "$tree/repo/nixos/packages/atc.nix" << 'EOF'
  version = "4.3.0";
  sha256 = "4444444444444444444444444444444444444444444444444444444444444444";
EOF
  diff - "$tree/repo/deploy/atc-gateway/versions.env" << 'EOF'
ATC_RELEASE=@zgeoff/atc@4.3.0
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=2222222222222222222222222222222222222222222222222222222222222222
GATEWAY_IMAGE_TAG=4.3.0
EOF
  diff - "$tree/out" << 'EOF'
atc 4.4.0 is pinned, which is newer than 4.3.0
pinned atc 4.3.0 in nixos/packages/atc.nix: 4444444444444444444444444444444444444444444444444444444444444444
pinned atc 4.3.0 in deploy/atc-gateway/versions.env: 2222222222222222222222222222222222222222222222222222222222222222
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_reports_a_release_that_every_file_already_pins() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=4.3.0
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
EOF
  cat > "$tree/repo/nixos/packages/atc.nix" << 'EOF'
  version = "4.3.0";
  sha256 = "4444444444444444444444444444444444444444444444444444444444444444";
EOF
  cat > "$tree/repo/deploy/atc-gateway/versions.env" << 'EOF'
ATC_RELEASE=@zgeoff/atc@4.3.0
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=2222222222222222222222222222222222222222222222222222222222222222
GATEWAY_IMAGE_TAG=4.3.0
EOF
  cp -pr "$tree/repo" "$tree/before"
  cat > "$tree/SHA256SUMS" << 'EOF'
2222222222222222222222222222222222222222222222222222222222222222  atc-gateway-linux-x64
4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64
EOF

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 4.3.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff -r "$tree/before" "$tree/repo"
  diff - "$tree/out" << 'EOF'
nixos/packages/atc.nix already pins atc 4.3.0
deploy/atc-gateway/versions.env already pins atc 4.3.0
atc 4.3.0 is already pinned
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_refuses_the_release_pinned_with_another_sum_without_writing_any_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=4.2.0
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  cat > "$tree/repo/nixos/packages/atc.nix" << 'EOF'
  version = "4.3.0";
  sha256 = "5555555555555555555555555555555555555555555555555555555555555555";
EOF
  cat > "$tree/repo/deploy/atc-gateway/versions.env" << 'EOF'
ATC_RELEASE=@zgeoff/atc@2.27.0
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=b6f3e54077e05bce6db35e12807eecebf4ac3ee988a7ca4abadb48d8fd602e6d
GATEWAY_IMAGE_TAG=2.27.0
EOF
  cp -pr "$tree/repo" "$tree/before"
  cat > "$tree/SHA256SUMS" << 'EOF'
2222222222222222222222222222222222222222222222222222222222222222  atc-gateway-linux-x64
4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64
EOF

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 4.3.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff -r "$tree/before" "$tree/repo"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'nixos/packages/atc.nix pins atc 4.3.0 with sum 5555555555555555555555555555555555555555555555555555555555555555, but SHA256SUMS lists 4444444444444444444444444444444444444444444444444444444444444444'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_sums_without_the_gateway_asset_without_writing_any_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=4.2.0
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  cat > "$tree/repo/nixos/packages/atc.nix" << 'EOF'
  version = "2.26.2";
  sha256 = "4d92b125a68edbd067ea0eaac493790402baa9102229df2843dea962250602e7";
EOF
  cat > "$tree/repo/deploy/atc-gateway/versions.env" << 'EOF'
ATC_RELEASE=@zgeoff/atc@2.27.0
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=b6f3e54077e05bce6db35e12807eecebf4ac3ee988a7ca4abadb48d8fd602e6d
GATEWAY_IMAGE_TAG=2.27.0
EOF
  cp -pr "$tree/repo" "$tree/before"
  echo '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 4.3.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff -r "$tree/before" "$tree/repo"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'SHA256SUMS has 0 atc-gateway-linux-x64 lines, want 1'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_a_file_with_two_version_lines_without_writing_any_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=4.2.0
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  cat > "$tree/repo/nixos/packages/atc.nix" << 'EOF'
  version = "2.26.2";
  version = "2.26.1";
  sha256 = "4d92b125a68edbd067ea0eaac493790402baa9102229df2843dea962250602e7";
EOF
  cat > "$tree/repo/deploy/atc-gateway/versions.env" << 'EOF'
ATC_RELEASE=@zgeoff/atc@2.27.0
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=b6f3e54077e05bce6db35e12807eecebf4ac3ee988a7ca4abadb48d8fd602e6d
GATEWAY_IMAGE_TAG=2.27.0
EOF
  cp -pr "$tree/repo" "$tree/before"
  cat > "$tree/SHA256SUMS" << 'EOF'
2222222222222222222222222222222222222222222222222222222222222222  atc-gateway-linux-x64
4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64
EOF

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 4.3.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff -r "$tree/before" "$tree/repo"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "nixos/packages/atc.nix has 2 lines that match '^  version = \"(.*)\";\$', want 1"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_prints_its_usage_without_a_sha256sums_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 4.3.0) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: pin-atc.sh <version> <SHA256SUMS file>'
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_refuses_a_version_that_is_not_a_release() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 4.3 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "not a release version: '4.3'"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

run_cases
