#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for publish-pepys-image.sh: in a copy of the script with the case's own pins and a written
# build context, it logs docker in with the token on stdin, builds the image on the pinned base,
# pushes the tag of the pinned release and the commit when the registry confirms it missing and records its digest in the step
# summary, skips a published tag, stops on a lookup it cannot read, and refuses a commit that is
# not a full hash. docker is a stand-in that logs its argv to the case's call log, so no case
# reaches a registry. Each case runs the script under `env -i` and compares its whole stdout,
# stderr, call log and summary.
#
#   bash scripts/run-bats.sh
#   CASE='published' bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-publish-docker.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  scripts="$BATS_TEST_DIRNAME"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# setup_test <tree>: a repo copy at <tree>/repo holding the publish script, the versions.env files
# that pin an example base and release v0.4.0, and a build context with a Dockerfile and a binary; the docker stand-in in
# <tree>/bin; the HOME and TMPDIR the script runs with, and empty registry and digest directories
# for the cases to fill
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/registry" "$tree/digests" \
    "$tree/repo/scripts" "$tree/repo/images/atc-gateway" "$tree/repo/images/pepys" "$tree/repo/context"
  cp "$scripts/publish-pepys-image.sh" "$tree/repo/scripts/"
  echo 'BASE_IMAGE=example.invalid/base:1' > "$tree/repo/images/atc-gateway/versions.env"
  echo 'PEPYS_RELEASE=v0.4.0' > "$tree/repo/images/pepys/versions.env"
  echo 'FROM scratch' > "$tree/repo/context/Dockerfile"
  echo fixture-binary > "$tree/repo/context/pepys-host"
  create_stub_publish_docker "$tree/bin"
}

@test "it pushes the image when the registry lacks its tag" {
  setup_test "$tree"
  echo sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    > "$tree/digests/ghcr.io_zgeoff_cloud-pepys_0.4.0-0123456789ab"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-pepys-image.sh context

  assert_output - << 'EOF'
Login Succeeded
The push refers to repository [ghcr.io/zgeoff/cloud-pepys]
EOF
  refute_stderr

  run -0 cmp <(printf '%s' dummy-token) "$tree/password"
  run -0 diff - "$tree/calls" << 'EOF'
["docker","login","ghcr.io","-u","octocat","--password-stdin"]
["docker","build","--build-arg","BASE_IMAGE=example.invalid/base:1","-t","ghcr.io/zgeoff/cloud-pepys:0.4.0-0123456789ab","context"]
["docker","manifest","inspect","ghcr.io/zgeoff/cloud-pepys:0.4.0-0123456789ab"]
["docker","push","ghcr.io/zgeoff/cloud-pepys:0.4.0-0123456789ab"]
["docker","inspect","--format","{{index .RepoDigests 0}}","ghcr.io/zgeoff/cloud-pepys:0.4.0-0123456789ab"]
EOF
  run -0 diff - "$tree/contexts/ghcr.io_zgeoff_cloud-pepys_0.4.0-0123456789ab" << 'EOF'
Dockerfile
pepys-host
EOF
  run -0 diff - "$tree/summary" << 'EOF'
ghcr.io/zgeoff/cloud-pepys:0.4.0-0123456789ab: ghcr.io/zgeoff/cloud-pepys@sha256:1111111111111111111111111111111111111111111111111111111111111111
EOF
}

@test "it skips a published tag" {
  setup_test "$tree"
  echo '{"digest":"sha256:3333333333333333333333333333333333333333333333333333333333333333"}' \
    > "$tree/registry/ghcr.io_zgeoff_cloud-pepys_0.4.0-0123456789ab"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-pepys-image.sh context

  assert_output 'Login Succeeded'
  refute_stderr

  jq -r '.[1]' "$tree/calls" > "$tree/commands"
  run -0 diff - "$tree/commands" << 'EOF'
login
build
manifest
EOF
  run -0 diff - "$tree/registry/ghcr.io_zgeoff_cloud-pepys_0.4.0-0123456789ab" <<< '{"digest":"sha256:3333333333333333333333333333333333333333333333333333333333333333"}'
  run -0 diff - "$tree/summary" <<< 'ghcr.io/zgeoff/cloud-pepys:0.4.0-0123456789ab: already published, not replaced'
}

@test "it stops without a push on a lookup it cannot read" {
  setup_test "$tree"
  echo 'Get "https://ghcr.io/v2/": dial tcp: lookup ghcr.io: no such host' > "$tree/registry-error"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-pepys-image.sh context

  assert_output 'Login Succeeded'
  assert_stderr 'cannot tell whether ghcr.io/zgeoff/cloud-pepys:0.4.0-0123456789ab exists: Get "https://ghcr.io/v2/": dial tcp: lookup ghcr.io: no such host'

  jq -r '.[1]' "$tree/calls" > "$tree/commands"
  run -0 diff - "$tree/commands" << 'EOF'
login
build
manifest
EOF
  [ ! -e "$tree/summary" ]
}

@test "it refuses a commit that is not a full hash" {
  setup_test "$tree"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_SHA=0123456 GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-pepys-image.sh context

  refute_output
  assert_stderr 'GITHUB_SHA must be a full commit hash: 0123456'

  [ ! -e "$tree/calls" ]
}

@test "it requires the token" {
  setup_test "$tree"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GITHUB_ACTOR=octocat GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-pepys-image.sh context

  refute_output
  assert_stderr 'scripts/publish-pepys-image.sh: line 21: GH_TOKEN: set GH_TOKEN to the token that pushes to ghcr.io'

  [ ! -e "$tree/calls" ]
}

@test "it refuses a release pin that is not a version" {
  setup_test "$tree"
  echo 'PEPYS_RELEASE=latest' > "$tree/repo/images/pepys/versions.env"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-pepys-image.sh context

  refute_output
  assert_stderr 'PEPYS_RELEASE must be v<major>.<minor>.<patch>: latest'

  [ ! -e "$tree/calls" ]
}

@test "it refuses a call without the context" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-pepys-image.sh

  refute_output
  assert_stderr 'usage: publish-pepys-image.sh <context>'

  [ ! -e "$tree/calls" ]
}
