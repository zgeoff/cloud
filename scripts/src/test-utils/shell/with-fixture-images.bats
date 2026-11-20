#!/usr/bin/env bats
# bats file_tags=suite:fixture-images
# Test for with-fixture-images.sh: with_fixture_images builds both fixture images under
# per-run tags, runs a command with them in its environment, removes them, and returns
# the command's status; a failed build runs nothing. It needs Docker and builds the
# images once, in the case that runs a command.
#
#   bash scripts/run-bats.sh fixture-images
#
# It tests the wrapper itself, so it runs outside it, in its own group.

# the case that runs a command builds both images
export BATS_TEST_TIMEOUT=600

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-gh.sh'
  load 'start-stub-github-api.sh'
  load 'with-fixture-images.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
  kill "$(cat "$tree/github/pid" 2> /dev/null)" 2> /dev/null || true
}

# The command checks that both images exist while it runs, then exits 7. The run id is
# random, so the case reads it from the output, then diffs the whole output with it.
@test "it runs the command with both images built then removes them and returns its status" {
  local status=0
  local run_id

  # shellcheck disable=SC2016 # expanded by the command's own shell
  with_fixture_images bash -c 'docker image inspect "$FIXTURE_GATEWAY_IMAGE" "$FIXTURE_BACKUP_IMAGE" > /dev/null &&
    echo "run=$FIXTURE_RUN gateway=$FIXTURE_GATEWAY_IMAGE backup=$FIXTURE_BACKUP_IMAGE"; exit 7' \
    > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 7

  run_id="$(sed -n 's/^run=\([0-9a-f]\{8\}\) .*$/\1/p' < "$tree/out")"
  [ -n "$run_id" ] || {
    cat "$tree/out" >&2
    echo "no run id in the output" >&2
    return 1
  }
  diff - "$tree/out" << EOF
built atc-gateway:fixture-$run_id and atc-gateway-backup:fixture-$run_id
run=$run_id gateway=atc-gateway:fixture-$run_id backup=atc-gateway-backup:fixture-$run_id
EOF
  diff /dev/null "$tree/err"
  docker images -q --filter "reference=atc-gateway:fixture-$run_id" > "$tree/gateway-left"
  docker images -q --filter "reference=atc-gateway-backup:fixture-$run_id" > "$tree/backup-left"
  diff /dev/null "$tree/gateway-left"
  diff /dev/null "$tree/backup-left"
}

# GH_HOST, SSL_CERT_FILE and an empty SSL_CERT_DIR point gh at the GitHub API stand-in on
# loopback, which knows no release, and the opt-outs turn off gh's telemetry and update
# check, so nothing leaves the machine. gh sends its release lookup and its draft
# GraphQL query at once; the stand-in answers both as missing, so gh reports "release not
# found" whichever answer lands first. The lookup's path carries the pinned release tag
# with its slash escaped, as gh escapes it, so the case reads the tag from the pins; the
# requests are sorted because the two lookups' order is not part of the contract.
@test "it reports a failed build with its log and runs nothing" {
  local status=0
  local release
  mkdir "$tree/github" "$tree/gh" "$tree/home" "$tree/tmp" "$tree/no-certs"
  start_stub_github_api "$tree/github" 3>&-
  sed -n 's/^ATC_RELEASE=//p' "$BATS_TEST_DIRNAME/../../../../images/atc-gateway/versions.env" > "$tree/release"
  release="$(< "$tree/release")"

  # shellcheck disable=SC2016 # expanded by the inner shell
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GH_CONFIG_DIR="$tree/gh" \
    GH_TELEMETRY=0 DO_NOT_TRACK=1 GH_NO_UPDATE_NOTIFIER=1 \
    GH_HOST="127.0.0.1:$(cat "$tree/github/port")" SSL_CERT_FILE="$tree/github/cert.pem" \
    SSL_CERT_DIR="$tree/no-certs" bash -c 'source "$1"; with_fixture_images touch "$2/ran"' _ \
    "$BATS_TEST_DIRNAME/with-fixture-images.sh" "$tree" > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 1

  diff - "$tree/out" << 'EOF'
FAIL the images did not build from the pinned, checked binary and pinned bases
    release not found
EOF
  diff /dev/null "$tree/err"
  sort "$tree/github/requests" > "$tree/requests"
  diff - "$tree/requests" << EOF
GET /api/v3/repos/zgeoff/atc/releases/tags/${release//\//%2F}
POST /api/graphql RepositoryReleaseByTag tagName=$release
EOF
  # gh sent no unexpected request, and the command did not run after a failed build
  refute [ -e "$tree/github/unexpected" ]
  refute [ -L "$tree/github/unexpected" ]
  refute [ -e "$tree/ran" ]
  refute [ -L "$tree/ran" ]
}

# A gh stand-in first on PATH answers the release fetch only when gh runs with all three
# opt-outs. The case passes none of them itself, so a match shows the helper's own; a call
# without one matches no recorded answer and ends with exit 97 and "unexpected: <argv>", so the
# output would differ. The recorded answer is gh's for a missing release, "release not found"
# and exit 1, which start-stub-github-api.bats pins against the real gh, so nothing is fetched
# or built.
@test "it runs the release fetch with ghs telemetry and update check off" {
  local status=0
  local release
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
  sed -n 's/^ATC_RELEASE=//p' "$BATS_TEST_DIRNAME/../../../../images/atc-gateway/versions.env" > "$tree/release"
  release="$(< "$tree/release")"
  jq -cn --arg release "$release" '{
    argv: ["gh", "release", "download", $release, "-R", "zgeoff/atc", "-p", "atc-gateway-linux-x64", "-p", "SHA256SUMS", "-D", null],
    env: {"GH_TELEMETRY": "0", "DO_NOT_TRACK": "1", "GH_NO_UPDATE_NOTIFIER": "1"},
    stderr: "release not found\n", exit: 1}' > "$tree/gh-responses"

  # shellcheck disable=SC2016 # expanded by the inner shell
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash -c 'source "$1"; with_fixture_images touch "$2/ran"' _ \
    "$BATS_TEST_DIRNAME/with-fixture-images.sh" "$tree" > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 1

  # the fetch downloads into its own mktemp directory under TMPDIR, so that path is masked
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|WORK|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" <<< "[\"gh\",\"release\",\"download\",\"$release\",\"-R\",\"zgeoff/atc\",\"-p\",\"atc-gateway-linux-x64\",\"-p\",\"SHA256SUMS\",\"-D\",\"WORK\"]"
  diff - "$tree/out" << 'EOF'
FAIL the images did not build from the pinned, checked binary and pinned bases
    release not found
EOF
  diff /dev/null "$tree/err"
  refute [ -e "$tree/ran" ]
  refute [ -L "$tree/ran" ]
}
