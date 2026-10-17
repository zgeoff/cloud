#!/usr/bin/env bash
# Test for publish-atc-gateway-images.sh: in a copy of the repo's publish files with the case's
# own pins, it logs docker in with the token on stdin, fetches and checks the pinned release into
# context/, builds both images, pushes each tag the registry confirms missing and records its
# digest in the step summary, skips a published tag, stops on a lookup it cannot read, stops
# before any build when the release fetch or its pin check fails, and requires each GitHub
# variable it reads. docker and gh are stand-ins that log their argv to the case's call log, so no
# case reaches a registry or GitHub. Each case runs the script under `env -i` and compares its
# whole stdout, stderr, call log and summary, masking only fetch-atc-release.sh's temp directory.
#
#   bash scripts/test-publish-atc-gateway-images.sh
#   CASE='published' bash scripts/test-publish-atc-gateway-images.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-publish-docker.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

it_pushes_both_images_when_the_registry_lacks_both_tags() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo fixture-binary > "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/atc-gateway-linux-x64"
  sum="$(sha256sum < "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/atc-gateway-linux-x64" | cut -d' ' -f1)"
  echo "$sum  atc-gateway-linux-x64" > "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/SHA256SUMS"
  # gh copies each asset a -p names into the -D directory, fetch-atc-release.sh's temp directory
  jq -cn --arg release "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0" '{
    argv: ["gh", "release", "download", "@zgeoff/atc@2.27.0", "-R", "zgeoff/atc", "-p", "atc-gateway-linux-x64", "-p", "SHA256SUMS", "-D", null],
    downloads: {"atc-gateway-linux-x64": "\($release)/atc-gateway-linux-x64", "SHA256SUMS": "\($release)/SHA256SUMS"}}' \
    > "$tree/gh-responses"
  cat > "$tree/repo/images/atc-gateway/versions.env" << EOF
ATC_RELEASE=@zgeoff/atc@2.27.0
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=$sum
GATEWAY_IMAGE_TAG=2.27.0
BACKUP_IMAGE_TAG=2.24.0-r2
BASE_IMAGE=example.invalid/base:1
RESTIC_IMAGE=example.invalid/restic:1
EOF
  echo sha256:1111111111111111111111111111111111111111111111111111111111111111 > "$tree/digests/ghcr.io_zgeoff_atc-gateway_2.27.0"
  echo sha256:2222222222222222222222222222222222222222222222222222222222222222 > "$tree/digests/ghcr.io_zgeoff_atc-gateway-backup_2.24.0-r2"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-atc-gateway-images.sh) > "$tree/out" 2> "$tree/err" || status=$?

  sed "s|$tree/tmp/tmp\.[A-Za-z0-9]*|<work>|g" "$tree/out" > "$tree/out.masked"
  diff - "$tree/out.masked" << 'EOF'
Login Succeeded
atc-gateway-linux-x64: OK
<work>/atc-gateway-linux-x64: OK
The push refers to repository [ghcr.io/zgeoff/atc-gateway]
The push refers to repository [ghcr.io/zgeoff/atc-gateway-backup]
EOF
  diff /dev/null "$tree/err"
  printf '%s' dummy-token | cmp - "$tree/password"
  sed "s|$tree/tmp/tmp\.[A-Za-z0-9]*|<work>|g" "$tree/calls" > "$tree/calls.masked"
  diff - "$tree/calls.masked" << 'EOF'
["docker","login","ghcr.io","-u","octocat","--password-stdin"]
["gh","release","download","@zgeoff/atc@2.27.0","-R","zgeoff/atc","-p","atc-gateway-linux-x64","-p","SHA256SUMS","-D","<work>"]
["docker","build","--build-arg","BASE_IMAGE=example.invalid/base:1","--build-arg","GATEWAY_PORT=8414","-t","ghcr.io/zgeoff/atc-gateway:2.27.0","context"]
["docker","build","--build-arg","RESTIC_IMAGE=example.invalid/restic:1","-t","ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2","images/atc-gateway/backup"]
["docker","manifest","inspect","ghcr.io/zgeoff/atc-gateway:2.27.0"]
["docker","push","ghcr.io/zgeoff/atc-gateway:2.27.0"]
["docker","inspect","--format","{{index .RepoDigests 0}}","ghcr.io/zgeoff/atc-gateway:2.27.0"]
["docker","manifest","inspect","ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2"]
["docker","push","ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2"]
["docker","inspect","--format","{{index .RepoDigests 0}}","ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2"]
EOF
  diff - "$tree/contexts/ghcr.io_zgeoff_atc-gateway_2.27.0" << 'EOF'
Dockerfile
atc-gateway
EOF
  cmp "$scripts/../images/atc-gateway/Dockerfile" "$tree/repo/context/Dockerfile"
  cmp "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/atc-gateway-linux-x64" "$tree/repo/context/atc-gateway"
  diff - "$tree/summary" << 'EOF'
ghcr.io/zgeoff/atc-gateway:2.27.0: ghcr.io/zgeoff/atc-gateway@sha256:1111111111111111111111111111111111111111111111111111111111111111
ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2: ghcr.io/zgeoff/atc-gateway-backup@sha256:2222222222222222222222222222222222222222222222222222222222222222
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_skips_a_published_tag_and_pushes_the_other() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo fixture-binary > "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/atc-gateway-linux-x64"
  sum="$(sha256sum < "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/atc-gateway-linux-x64" | cut -d' ' -f1)"
  echo "$sum  atc-gateway-linux-x64" > "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/SHA256SUMS"
  # gh copies each asset a -p names into the -D directory, fetch-atc-release.sh's temp directory
  jq -cn --arg release "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0" '{
    argv: ["gh", "release", "download", "@zgeoff/atc@2.27.0", "-R", "zgeoff/atc", "-p", "atc-gateway-linux-x64", "-p", "SHA256SUMS", "-D", null],
    downloads: {"atc-gateway-linux-x64": "\($release)/atc-gateway-linux-x64", "SHA256SUMS": "\($release)/SHA256SUMS"}}' \
    > "$tree/gh-responses"
  cat > "$tree/repo/images/atc-gateway/versions.env" << EOF
ATC_RELEASE=@zgeoff/atc@2.27.0
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=$sum
GATEWAY_IMAGE_TAG=2.27.0
BACKUP_IMAGE_TAG=2.24.0-r2
BASE_IMAGE=example.invalid/base:1
RESTIC_IMAGE=example.invalid/restic:1
EOF
  echo '{"digest":"sha256:3333333333333333333333333333333333333333333333333333333333333333"}' > "$tree/registry/ghcr.io_zgeoff_atc-gateway_2.27.0"
  echo sha256:2222222222222222222222222222222222222222222222222222222222222222 > "$tree/digests/ghcr.io_zgeoff_atc-gateway-backup_2.24.0-r2"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-atc-gateway-images.sh) > "$tree/out" 2> "$tree/err" || status=$?

  sed "s|$tree/tmp/tmp\.[A-Za-z0-9]*|<work>|g" "$tree/out" > "$tree/out.masked"
  diff - "$tree/out.masked" << 'EOF'
Login Succeeded
atc-gateway-linux-x64: OK
<work>/atc-gateway-linux-x64: OK
The push refers to repository [ghcr.io/zgeoff/atc-gateway-backup]
EOF
  diff /dev/null "$tree/err"
  sed "s|$tree/tmp/tmp\.[A-Za-z0-9]*|<work>|g" "$tree/calls" > "$tree/calls.masked"
  diff - "$tree/calls.masked" << 'EOF'
["docker","login","ghcr.io","-u","octocat","--password-stdin"]
["gh","release","download","@zgeoff/atc@2.27.0","-R","zgeoff/atc","-p","atc-gateway-linux-x64","-p","SHA256SUMS","-D","<work>"]
["docker","build","--build-arg","BASE_IMAGE=example.invalid/base:1","--build-arg","GATEWAY_PORT=8414","-t","ghcr.io/zgeoff/atc-gateway:2.27.0","context"]
["docker","build","--build-arg","RESTIC_IMAGE=example.invalid/restic:1","-t","ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2","images/atc-gateway/backup"]
["docker","manifest","inspect","ghcr.io/zgeoff/atc-gateway:2.27.0"]
["docker","manifest","inspect","ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2"]
["docker","push","ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2"]
["docker","inspect","--format","{{index .RepoDigests 0}}","ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2"]
EOF
  diff - "$tree/registry/ghcr.io_zgeoff_atc-gateway_2.27.0" <<< '{"digest":"sha256:3333333333333333333333333333333333333333333333333333333333333333"}'
  diff - "$tree/summary" << 'EOF'
ghcr.io/zgeoff/atc-gateway:2.27.0: already published, not replaced
ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2: ghcr.io/zgeoff/atc-gateway-backup@sha256:2222222222222222222222222222222222222222222222222222222222222222
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_stops_without_a_push_on_a_lookup_it_cannot_read() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo fixture-binary > "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/atc-gateway-linux-x64"
  sum="$(sha256sum < "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/atc-gateway-linux-x64" | cut -d' ' -f1)"
  echo "$sum  atc-gateway-linux-x64" > "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/SHA256SUMS"
  # gh copies each asset a -p names into the -D directory, fetch-atc-release.sh's temp directory
  jq -cn --arg release "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0" '{
    argv: ["gh", "release", "download", "@zgeoff/atc@2.27.0", "-R", "zgeoff/atc", "-p", "atc-gateway-linux-x64", "-p", "SHA256SUMS", "-D", null],
    downloads: {"atc-gateway-linux-x64": "\($release)/atc-gateway-linux-x64", "SHA256SUMS": "\($release)/SHA256SUMS"}}' \
    > "$tree/gh-responses"
  cat > "$tree/repo/images/atc-gateway/versions.env" << EOF
ATC_RELEASE=@zgeoff/atc@2.27.0
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=$sum
GATEWAY_IMAGE_TAG=2.27.0
BACKUP_IMAGE_TAG=2.24.0-r2
BASE_IMAGE=example.invalid/base:1
RESTIC_IMAGE=example.invalid/restic:1
EOF
  echo 'Get "https://ghcr.io/v2/": dial tcp: lookup ghcr.io: no such host' > "$tree/registry-error"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-atc-gateway-images.sh) > "$tree/out" 2> "$tree/err" || status=$?

  sed "s|$tree/tmp/tmp\.[A-Za-z0-9]*|<work>|g" "$tree/out" > "$tree/out.masked"
  diff - "$tree/out.masked" << 'EOF'
Login Succeeded
atc-gateway-linux-x64: OK
<work>/atc-gateway-linux-x64: OK
EOF
  diff - "$tree/err" <<< 'cannot tell whether ghcr.io/zgeoff/atc-gateway:2.27.0 exists: Get "https://ghcr.io/v2/": dial tcp: lookup ghcr.io: no such host'
  jq -r '.[1]' "$tree/calls" > "$tree/commands"
  diff - "$tree/commands" << 'EOF'
login
release
build
build
manifest
EOF
  [ ! -e "$tree/summary" ]
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_stops_before_any_build_when_the_release_is_missing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/atc-gateway/versions.env" << 'EOF'
ATC_RELEASE=@zgeoff/atc@9.9.9
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=1111111111111111111111111111111111111111111111111111111111111111
GATEWAY_IMAGE_TAG=9.9.9
BACKUP_IMAGE_TAG=2.24.0-r2
BASE_IMAGE=example.invalid/base:1
RESTIC_IMAGE=example.invalid/restic:1
EOF
  # gh's answer for a release the repository lacks, which test-start-stub-github-api.sh pins
  # against the real gh: "release not found" on stderr, exit 1, nothing downloaded
  cat > "$tree/gh-responses" << 'EOF'
{"argv": ["gh", "release", "download", "@zgeoff/atc@9.9.9", "-R", "zgeoff/atc", "-p", "atc-gateway-linux-x64", "-p", "SHA256SUMS", "-D", null], "stderr": "release not found\n", "exit": 1}
EOF

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-atc-gateway-images.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'Login Succeeded'
  diff - "$tree/err" <<< 'release not found'
  jq -r '.[1]' "$tree/calls" > "$tree/commands"
  diff - "$tree/commands" << 'EOF'
login
release
EOF
  [ ! -e "$tree/summary" ]
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_stops_before_any_build_when_the_asset_fails_the_pin() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo fixture-binary > "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/atc-gateway-linux-x64"
  sum="$(sha256sum < "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/atc-gateway-linux-x64" | cut -d' ' -f1)"
  echo "$sum  atc-gateway-linux-x64" > "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0/SHA256SUMS"
  # gh copies each asset a -p names into the -D directory, fetch-atc-release.sh's temp directory
  jq -cn --arg release "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0" '{
    argv: ["gh", "release", "download", "@zgeoff/atc@2.27.0", "-R", "zgeoff/atc", "-p", "atc-gateway-linux-x64", "-p", "SHA256SUMS", "-D", null],
    downloads: {"atc-gateway-linux-x64": "\($release)/atc-gateway-linux-x64", "SHA256SUMS": "\($release)/SHA256SUMS"}}' \
    > "$tree/gh-responses"
  cat > "$tree/repo/images/atc-gateway/versions.env" << 'EOF'
ATC_RELEASE=@zgeoff/atc@2.27.0
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=1111111111111111111111111111111111111111111111111111111111111111
GATEWAY_IMAGE_TAG=2.27.0
BACKUP_IMAGE_TAG=2.24.0-r2
BASE_IMAGE=example.invalid/base:1
RESTIC_IMAGE=example.invalid/restic:1
EOF

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-atc-gateway-images.sh) > "$tree/out" 2> "$tree/err" || status=$?

  sed "s|$tree/tmp/tmp\.[A-Za-z0-9]*|<work>|g" "$tree/out" > "$tree/out.masked"
  diff - "$tree/out.masked" << 'EOF'
Login Succeeded
atc-gateway-linux-x64: OK
<work>/atc-gateway-linux-x64: FAILED
EOF
  diff - "$tree/err" <<< 'sha256sum: WARNING: 1 computed checksum did NOT match'
  jq -r '.[1]' "$tree/calls" > "$tree/commands"
  diff - "$tree/commands" << 'EOF'
login
release
EOF
  [ ! -e "$tree/repo/context" ]
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_requires_the_token() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GITHUB_ACTOR=octocat GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-atc-gateway-images.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'scripts/publish-atc-gateway-images.sh: line 14: GH_TOKEN: set GH_TOKEN to the token that pushes to ghcr.io'
  [ ! -e "$tree/calls" ]
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_requires_the_actor() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_STEP_SUMMARY="$tree/summary" bash scripts/publish-atc-gateway-images.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'scripts/publish-atc-gateway-images.sh: line 15: GITHUB_ACTOR: set GITHUB_ACTOR to the user the token belongs to'
  [ ! -e "$tree/calls" ]
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_requires_the_step_summary() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" GH_TOKEN=dummy-token GITHUB_ACTOR=octocat bash scripts/publish-atc-gateway-images.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'scripts/publish-atc-gateway-images.sh: line 16: GITHUB_STEP_SUMMARY: set GITHUB_STEP_SUMMARY to the file that records each image'
  [ ! -e "$tree/calls" ]
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

# setup_test <tree>: a repo copy at <tree>/repo holding the publish script, fetch-atc-release.sh,
# the gateway Dockerfile and the backup image's build context, with no versions.env, which each
# case writes; the docker and gh stand-ins in <tree>/bin, gh answering from <tree>/gh-responses,
# which each case that fetches writes; the HOME and TMPDIR the script runs with, and empty
# registry, digest and release directories for the cases to fill
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/registry" "$tree/digests" \
    "$tree/releases/zgeoff/atc/@zgeoff/atc@2.27.0" "$tree/repo/scripts" "$tree/repo/images/atc-gateway" \
    "$tree/repo/packages/topology"
  cp "$scripts/publish-atc-gateway-images.sh" "$scripts/fetch-atc-release.sh" "$tree/repo/scripts/"
  # the gateway image's build reads its port from the shared constants
  cp "$scripts/../packages/topology/constants.json" "$tree/repo/packages/topology/"
  cp "$scripts/../images/atc-gateway/Dockerfile" "$tree/repo/images/atc-gateway/"
  cp -r "$scripts/../images/atc-gateway/backup" "$tree/repo/images/atc-gateway/"
  create_stub_publish_docker "$tree/bin"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
}

run_cases
