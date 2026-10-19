#!/usr/bin/env bash
# Test for publish-files-image.sh: in a copy of the script with the case's own pins and a written
# build context, it logs docker in with the token on stdin, builds the image on the pinned base,
# pushes the commit's tag when the registry confirms it missing and records its digest in the step
# summary, skips a published tag, stops on a lookup it cannot read, and refuses a commit that is
# not a full hash. docker is a stand-in that logs its argv to the case's call log, so no case
# reaches a registry. Each case runs the script under `env -i` and compares its whole stdout,
# stderr, call log and summary.
#
#   bash scripts/test-publish-files-image.sh
#   CASE='published' bash scripts/test-publish-files-image.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-publish-docker.sh"

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

it_pushes_the_image_when_the_registry_lacks_its_tag() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    > "$tree/digests/ghcr.io_zgeoff_cloud-files_0123456789abcdef0123456789abcdef01234567"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-files-image.sh context) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
Login Succeeded
The push refers to repository [ghcr.io/zgeoff/cloud-files]
EOF
  diff /dev/null "$tree/err"
  printf '%s' dummy-token | cmp - "$tree/password"
  diff - "$tree/calls" << 'EOF'
["docker","login","ghcr.io","-u","octocat","--password-stdin"]
["docker","build","--build-arg","BASE_IMAGE=example.invalid/base:1","-t","ghcr.io/zgeoff/cloud-files:0123456789abcdef0123456789abcdef01234567","context"]
["docker","manifest","inspect","ghcr.io/zgeoff/cloud-files:0123456789abcdef0123456789abcdef01234567"]
["docker","push","ghcr.io/zgeoff/cloud-files:0123456789abcdef0123456789abcdef01234567"]
["docker","inspect","--format","{{index .RepoDigests 0}}","ghcr.io/zgeoff/cloud-files:0123456789abcdef0123456789abcdef01234567"]
EOF
  diff - "$tree/contexts/ghcr.io_zgeoff_cloud-files_0123456789abcdef0123456789abcdef01234567" << 'EOF'
Dockerfile
files
EOF
  diff - "$tree/summary" << 'EOF'
ghcr.io/zgeoff/cloud-files:0123456789abcdef0123456789abcdef01234567: ghcr.io/zgeoff/cloud-files@sha256:1111111111111111111111111111111111111111111111111111111111111111
EOF
  assert_status 0 "$status"
}

it_skips_a_published_tag() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo '{"digest":"sha256:3333333333333333333333333333333333333333333333333333333333333333"}' \
    > "$tree/registry/ghcr.io_zgeoff_cloud-files_0123456789abcdef0123456789abcdef01234567"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-files-image.sh context) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'Login Succeeded'
  diff /dev/null "$tree/err"
  jq -r '.[1]' "$tree/calls" > "$tree/commands"
  diff - "$tree/commands" << 'EOF'
login
build
manifest
EOF
  diff - "$tree/registry/ghcr.io_zgeoff_cloud-files_0123456789abcdef0123456789abcdef01234567" <<< '{"digest":"sha256:3333333333333333333333333333333333333333333333333333333333333333"}'
  diff - "$tree/summary" <<< 'ghcr.io/zgeoff/cloud-files:0123456789abcdef0123456789abcdef01234567: already published, not replaced'
  assert_status 0 "$status"
}

it_stops_without_a_push_on_a_lookup_it_cannot_read() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo 'Get "https://ghcr.io/v2/": dial tcp: lookup ghcr.io: no such host' > "$tree/registry-error"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-files-image.sh context) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'Login Succeeded'
  diff - "$tree/err" <<< 'cannot tell whether ghcr.io/zgeoff/cloud-files:0123456789abcdef0123456789abcdef01234567 exists: Get "https://ghcr.io/v2/": dial tcp: lookup ghcr.io: no such host'
  jq -r '.[1]' "$tree/calls" > "$tree/commands"
  diff - "$tree/commands" << 'EOF'
login
build
manifest
EOF
  [ ! -e "$tree/summary" ]
  assert_status 1 "$status"
}

it_refuses_a_commit_that_is_not_a_full_hash() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_SHA=0123456 GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-files-image.sh context) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'GITHUB_SHA must be a full commit hash: 0123456'
  [ ! -e "$tree/calls" ]
  assert_status 1 "$status"
}

it_requires_the_token() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GITHUB_ACTOR=octocat GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-files-image.sh context) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'scripts/publish-files-image.sh: line 19: GH_TOKEN: set GH_TOKEN to the token that pushes to ghcr.io'
  [ ! -e "$tree/calls" ]
  assert_status 1 "$status"
}

it_refuses_a_call_without_the_context() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-files-image.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: publish-files-image.sh <context>'
  [ ! -e "$tree/calls" ]
  assert_status 2 "$status"
}

# setup_test <tree>: a repo copy at <tree>/repo holding the publish script, a versions.env that
# pins an example base, and a build context with a Dockerfile and a binary; the docker stand-in in
# <tree>/bin; the HOME and TMPDIR the script runs with, and empty registry and digest directories
# for the cases to fill
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/registry" "$tree/digests" \
    "$tree/repo/scripts" "$tree/repo/images/atc-gateway" "$tree/repo/context"
  cp "$scripts/publish-files-image.sh" "$tree/repo/scripts/"
  echo 'BASE_IMAGE=example.invalid/base:1' > "$tree/repo/images/atc-gateway/versions.env"
  echo 'FROM scratch' > "$tree/repo/context/Dockerfile"
  echo fixture-binary > "$tree/repo/context/files"
  create_stub_publish_docker "$tree/bin"
}

run_cases
