#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for install-pulumi-cli.sh: in a copy of the script with the case's own infra/package.json,
# it downloads the tarball of the pinned @pulumi/pulumi release into RUNNER_TEMP, checks it against
# the release's checksum file, extracts it, adds RUNNER_TEMP/pulumi to GITHUB_PATH and installs the
# pinned Kubernetes plugin with it; a missing Kubernetes pin fails it; a checksum that does not
# match, a checksum file without the tarball and a failed download each fail it before anything is
# extracted; and it requires both GitHub variables. curl is a stand-in that
# serves the case's release files, so no case reaches get.pulumi.com. Each case runs the script
# under `env -i` and compares its whole stdout, stderr, call log and GITHUB_PATH.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-pulumi-curl.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  scripts="$BATS_TEST_DIRNAME"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
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

@test "it installs the pinned release and adds it to the path" {
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"1.2.3","@pulumi/kubernetes":"4.5.6"}}' > "$tree/repo/infra/package.json"
  mkdir -p "$tree/release/pulumi"
  printf '#!/bin/sh\necho "pulumi $*"\n' > "$tree/release/pulumi/pulumi"
  chmod +x "$tree/release/pulumi/pulumi"
  tar -C "$tree/release" -czf "$tree/pulumi/pulumi-v1.2.3-linux-x64.tar.gz" pulumi
  sum="$(sha256sum < "$tree/pulumi/pulumi-v1.2.3-linux-x64.tar.gz" | cut -d' ' -f1)"
  printf '%s  pulumi-v1.2.3-linux-x64.tar.gz\n%s  pulumi-v1.2.3-darwin-arm64.tar.gz\n' "$sum" "$sum" > "$tree/pulumi/pulumi-1.2.3-checksums.txt"
  echo /earlier/bin > "$tree/github-path"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" RUNNER_TEMP="$tree/runner-temp" GITHUB_PATH="$tree/github-path" bash scripts/install-pulumi-cli.sh

  assert_output - << 'EOF'
pulumi-v1.2.3-linux-x64.tar.gz: OK
pulumi plugin install resource kubernetes 4.5.6
EOF
  refute_stderr

  run -0 diff - "$tree/calls" << 'EOF'
["curl","-fsSLO","https://get.pulumi.com/releases/sdk/pulumi-v1.2.3-linux-x64.tar.gz"]
["curl","-fsSL","https://get.pulumi.com/releases/sdk/pulumi-1.2.3-checksums.txt"]
EOF
  cmp "$tree/release/pulumi/pulumi" "$tree/runner-temp/pulumi/pulumi"
  run -0 diff - "$tree/github-path" << EOF
/earlier/bin
$tree/runner-temp/pulumi
EOF
}

@test "it installs no plugin when infra pins no kubernetes provider" {
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"1.2.3"}}' > "$tree/repo/infra/package.json"
  mkdir -p "$tree/release/pulumi"
  printf '#!/bin/sh\necho "pulumi $*"\n' > "$tree/release/pulumi/pulumi"
  chmod +x "$tree/release/pulumi/pulumi"
  tar -C "$tree/release" -czf "$tree/pulumi/pulumi-v1.2.3-linux-x64.tar.gz" pulumi
  sum="$(sha256sum < "$tree/pulumi/pulumi-v1.2.3-linux-x64.tar.gz" | cut -d' ' -f1)"
  echo "$sum  pulumi-v1.2.3-linux-x64.tar.gz" > "$tree/pulumi/pulumi-1.2.3-checksums.txt"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" RUNNER_TEMP="$tree/runner-temp" GITHUB_PATH="$tree/github-path" bash scripts/install-pulumi-cli.sh

  assert_output 'pulumi-v1.2.3-linux-x64.tar.gz: OK'
  refute_stderr
}

@test "it refuses a tarball whose checksum does not match" {
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"1.2.3"}}' > "$tree/repo/infra/package.json"
  mkdir -p "$tree/release/pulumi"
  printf '#!/bin/sh\necho pulumi\n' > "$tree/release/pulumi/pulumi"
  tar -C "$tree/release" -czf "$tree/pulumi/pulumi-v1.2.3-linux-x64.tar.gz" pulumi
  echo '1111111111111111111111111111111111111111111111111111111111111111  pulumi-v1.2.3-linux-x64.tar.gz' > "$tree/pulumi/pulumi-1.2.3-checksums.txt"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" RUNNER_TEMP="$tree/runner-temp" GITHUB_PATH="$tree/github-path" bash scripts/install-pulumi-cli.sh

  assert_output 'pulumi-v1.2.3-linux-x64.tar.gz: FAILED'
  assert_stderr 'sha256sum: WARNING: 1 computed checksum did NOT match'

  [ ! -e "$tree/runner-temp/pulumi" ]
  [ ! -e "$tree/github-path" ]
}

@test "it fails when the checksum file lacks the tarball" {
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"1.2.3"}}' > "$tree/repo/infra/package.json"
  mkdir -p "$tree/release/pulumi"
  printf '#!/bin/sh\necho pulumi\n' > "$tree/release/pulumi/pulumi"
  tar -C "$tree/release" -czf "$tree/pulumi/pulumi-v1.2.3-linux-x64.tar.gz" pulumi
  echo '1111111111111111111111111111111111111111111111111111111111111111  pulumi-v1.2.3-darwin-arm64.tar.gz' > "$tree/pulumi/pulumi-1.2.3-checksums.txt"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" RUNNER_TEMP="$tree/runner-temp" GITHUB_PATH="$tree/github-path" bash scripts/install-pulumi-cli.sh

  refute_output
  assert_stderr "sha256sum: 'standard input': no properly formatted checksum lines found"

  [ ! -e "$tree/runner-temp/pulumi" ]
  [ ! -e "$tree/github-path" ]
}

@test "it fails with curls error when the release is missing" {
  setup_test "$tree"
  echo '{"dependencies":{"@pulumi/pulumi":"9.9.9"}}' > "$tree/repo/infra/package.json"

  run -22 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" RUNNER_TEMP="$tree/runner-temp" GITHUB_PATH="$tree/github-path" bash scripts/install-pulumi-cli.sh

  refute_output
  assert_stderr 'curl: (22) The requested URL returned error: 404'

  run -0 diff - "$tree/calls" <<< '["curl","-fsSLO","https://get.pulumi.com/releases/sdk/pulumi-v9.9.9-linux-x64.tar.gz"]'
  [ ! -e "$tree/github-path" ]
}

@test "it requires the runner temp directory" {
  setup_test "$tree"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GITHUB_PATH="$tree/github-path" bash scripts/install-pulumi-cli.sh

  refute_output
  assert_stderr 'scripts/install-pulumi-cli.sh: line 13: RUNNER_TEMP: set RUNNER_TEMP to the directory the CLI goes in'

  [ ! -e "$tree/calls" ]
}

@test "it requires the github path file" {
  setup_test "$tree"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" RUNNER_TEMP="$tree/runner-temp" bash scripts/install-pulumi-cli.sh

  refute_output
  assert_stderr 'scripts/install-pulumi-cli.sh: line 14: GITHUB_PATH: set GITHUB_PATH to the file that takes the paths for later steps'

  [ ! -e "$tree/calls" ]
}
