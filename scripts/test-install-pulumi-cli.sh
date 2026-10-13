#!/usr/bin/env bash
# Test for install-pulumi-cli.sh: in a copy of the script with the case's own infra/package.json,
# it downloads the tarball of the pinned @pulumi/pulumi release into RUNNER_TEMP, checks it against
# the release's checksum file, extracts it and adds RUNNER_TEMP/pulumi to GITHUB_PATH; a checksum
# that does not match, a checksum file without the tarball and a failed download each fail it
# before anything is extracted; and it requires both GitHub variables. curl is a stand-in that
# serves the case's release files, so no case reaches get.pulumi.com. Each case runs the script
# under `env -i` and compares its whole stdout, stderr, call log and GITHUB_PATH.
#
#   bash scripts/test-install-pulumi-cli.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-pulumi-curl.sh"

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

it_installs_the_pinned_release_and_adds_it_to_the_path() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"1.2.3"}}' > "$tree/repo/infra/package.json"
  mkdir -p "$tree/release/pulumi"
  printf '#!/bin/sh\necho pulumi\n' > "$tree/release/pulumi/pulumi"
  chmod +x "$tree/release/pulumi/pulumi"
  tar -C "$tree/release" -czf "$tree/pulumi/pulumi-v1.2.3-linux-x64.tar.gz" pulumi
  sum="$(sha256sum < "$tree/pulumi/pulumi-v1.2.3-linux-x64.tar.gz" | cut -d' ' -f1)"
  printf '%s  pulumi-v1.2.3-linux-x64.tar.gz\n%s  pulumi-v1.2.3-darwin-arm64.tar.gz\n' "$sum" "$sum" > "$tree/pulumi/pulumi-1.2.3-checksums.txt"
  echo /earlier/bin > "$tree/github-path"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" RUNNER_TEMP="$tree/runner-temp" GITHUB_PATH="$tree/github-path" bash scripts/install-pulumi-cli.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'pulumi-v1.2.3-linux-x64.tar.gz: OK'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["curl","-fsSLO","https://get.pulumi.com/releases/sdk/pulumi-v1.2.3-linux-x64.tar.gz"]
["curl","-fsSL","https://get.pulumi.com/releases/sdk/pulumi-1.2.3-checksums.txt"]
EOF
  cmp "$tree/release/pulumi/pulumi" "$tree/runner-temp/pulumi/pulumi"
  diff - "$tree/github-path" << EOF
/earlier/bin
$tree/runner-temp/pulumi
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_refuses_a_tarball_whose_checksum_does_not_match() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"1.2.3"}}' > "$tree/repo/infra/package.json"
  mkdir -p "$tree/release/pulumi"
  printf '#!/bin/sh\necho pulumi\n' > "$tree/release/pulumi/pulumi"
  tar -C "$tree/release" -czf "$tree/pulumi/pulumi-v1.2.3-linux-x64.tar.gz" pulumi
  echo '1111111111111111111111111111111111111111111111111111111111111111  pulumi-v1.2.3-linux-x64.tar.gz' > "$tree/pulumi/pulumi-1.2.3-checksums.txt"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" RUNNER_TEMP="$tree/runner-temp" GITHUB_PATH="$tree/github-path" bash scripts/install-pulumi-cli.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'pulumi-v1.2.3-linux-x64.tar.gz: FAILED'
  diff - "$tree/err" <<< 'sha256sum: WARNING: 1 computed checksum did NOT match'
  [ ! -e "$tree/runner-temp/pulumi" ]
  [ ! -e "$tree/github-path" ]
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_when_the_checksum_file_lacks_the_tarball() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"1.2.3"}}' > "$tree/repo/infra/package.json"
  mkdir -p "$tree/release/pulumi"
  printf '#!/bin/sh\necho pulumi\n' > "$tree/release/pulumi/pulumi"
  tar -C "$tree/release" -czf "$tree/pulumi/pulumi-v1.2.3-linux-x64.tar.gz" pulumi
  echo '1111111111111111111111111111111111111111111111111111111111111111  pulumi-v1.2.3-darwin-arm64.tar.gz' > "$tree/pulumi/pulumi-1.2.3-checksums.txt"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" RUNNER_TEMP="$tree/runner-temp" GITHUB_PATH="$tree/github-path" bash scripts/install-pulumi-cli.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "sha256sum: 'standard input': no properly formatted checksum lines found"
  [ ! -e "$tree/runner-temp/pulumi" ]
  [ ! -e "$tree/github-path" ]
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_with_curls_error_when_the_release_is_missing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"9.9.9"}}' > "$tree/repo/infra/package.json"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" RUNNER_TEMP="$tree/runner-temp" GITHUB_PATH="$tree/github-path" bash scripts/install-pulumi-cli.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 404'
  diff - "$tree/calls" <<< '["curl","-fsSLO","https://get.pulumi.com/releases/sdk/pulumi-v9.9.9-linux-x64.tar.gz"]'
  [ ! -e "$tree/github-path" ]
  [ "$status" = 22 ] || {
    echo "exit $status, want 22" >&2
    exit 1
  }
}

it_requires_the_runner_temp_directory() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GITHUB_PATH="$tree/github-path" bash scripts/install-pulumi-cli.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'scripts/install-pulumi-cli.sh: line 12: RUNNER_TEMP: set RUNNER_TEMP to the directory the CLI goes in'
  [ ! -e "$tree/calls" ]
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_requires_the_github_path_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" RUNNER_TEMP="$tree/runner-temp" bash scripts/install-pulumi-cli.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'scripts/install-pulumi-cli.sh: line 13: GITHUB_PATH: set GITHUB_PATH to the file that takes the paths for later steps'
  [ ! -e "$tree/calls" ]
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

# setup_test <tree>: a repo copy at <tree>/repo holding the script and an empty infra/, which each
# case gives its package.json; the curl stand-in in <tree>/bin; the HOME, TMPDIR and RUNNER_TEMP
# the script runs with; and an empty release directory for the cases to fill
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/runner-temp" "$tree/pulumi" "$tree/repo/scripts" "$tree/repo/infra"
  cp "$scripts/install-pulumi-cli.sh" "$tree/repo/scripts/"
  create_stub_pulumi_curl "$tree/bin"
}

run_cases
