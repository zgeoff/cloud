#!/usr/bin/env bash
# Test for with-fixture-images.sh: with_fixture_images builds both fixture images under
# per-run tags, runs a command with them in its environment, removes them, and returns
# the command's status; a failed build runs nothing. It needs Docker and builds the
# images once, in the case that runs a command.
#
#   bash scripts/test-lib/test-with-fixture-images.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-gh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-stub-github-api.sh"
source "$(dirname "${BASH_SOURCE[0]}")/with-fixture-images.sh"

# The command checks that both images exist while it runs, then exits 7. The run id is
# random, so the case reads it from the output, then diffs the whole output with it.
it_runs_the_command_with_both_images_built_then_removes_them_and_returns_its_status() {
  local run status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree" || true' EXIT

  # shellcheck disable=SC2016 # expanded by the command's own shell
  with_fixture_images bash -c 'docker image inspect "$FIXTURE_GATEWAY_IMAGE" "$FIXTURE_BACKUP_IMAGE" > /dev/null &&
    echo "run=$FIXTURE_RUN gateway=$FIXTURE_GATEWAY_IMAGE backup=$FIXTURE_BACKUP_IMAGE"; exit 7' \
    > "$tree/out" 2> "$tree/err" || status=$?

  run="$(sed -n 's/^run=\([0-9a-f]\{8\}\) .*$/\1/p' "$tree/out")"
  [ -n "$run" ] || { cat "$tree/out"; echo "no run id in the output" >&2; exit 1; }
  diff - "$tree/out" << EOF
built atc-gateway:fixture-$run and atc-gateway-backup:fixture-$run
run=$run gateway=atc-gateway:fixture-$run backup=atc-gateway-backup:fixture-$run
EOF
  diff /dev/null "$tree/err"
  docker images -q --filter "reference=atc-gateway:fixture-$run" > "$tree/gateway-left"
  docker images -q --filter "reference=atc-gateway-backup:fixture-$run" > "$tree/backup-left"
  diff /dev/null "$tree/gateway-left"
  diff /dev/null "$tree/backup-left"
  [ "$status" = 7 ] || { echo "exit $status, want 7" >&2; exit 1; }
}

# GH_HOST, SSL_CERT_FILE and an empty SSL_CERT_DIR point gh at the GitHub API stand-in on
# loopback, which knows no release, and the opt-outs turn off gh's telemetry and update
# check, so nothing leaves the machine. gh sends its release lookup and its draft
# GraphQL query at once; the stand-in answers both as missing, so gh reports "release not
# found" whichever answer lands first. The lookup's path carries the pinned release tag
# with its slash escaped, as gh escapes it, so the case reads the tag from the pins; the
# requests are sorted because the two lookups' order is not part of the contract.
it_reports_a_failed_build_with_its_log_and_runs_nothing() {
  local release status=0
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/github/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  mkdir "$tree/github" "$tree/gh" "$tree/home" "$tree/tmp" "$tree/no-certs"
  start_stub_github_api "$tree/github"
  sed -n 's/^ATC_RELEASE=//p' "$(dirname "${BASH_SOURCE[0]}")/../../deploy/atc-gateway/versions.env" > "$tree/release"
  release="$(< "$tree/release")"

  # shellcheck disable=SC2016 # expanded by the inner shell
  env -i PATH="$PATH" HOME="$tree/home" TMPDIR="$tree/tmp" GH_CONFIG_DIR="$tree/gh" \
    GH_TELEMETRY=0 DO_NOT_TRACK=1 GH_NO_UPDATE_NOTIFIER=1 \
    GH_HOST="127.0.0.1:$(cat "$tree/github/port")" SSL_CERT_FILE="$tree/github/cert.pem" \
    SSL_CERT_DIR="$tree/no-certs" bash -c 'source "$1"; with_fixture_images touch "$2/ran"' _ \
    "$(dirname "${BASH_SOURCE[0]}")/with-fixture-images.sh" "$tree" \
    > "$tree/out" 2> "$tree/err" || status=$?

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
  [ ! -e "$tree/github/unexpected" ] || { echo "gh sent an unexpected request" >&2; exit 1; }
  [ ! -e "$tree/ran" ] || { echo "the command ran after a failed build" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# A gh stand-in first on PATH records the environment the release fetch gives gh. The case
# passes none of the opt-outs itself, so the recorded values are the helper's own; the
# stand-in answers that the release is missing, so nothing is fetched or built.
it_runs_the_release_fetch_with_ghs_telemetry_and_update_check_off() {
  local release status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree" || true' EXIT
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_gh "$tree/bin"
  sed -n 's/^ATC_RELEASE=//p' "$(dirname "${BASH_SOURCE[0]}")/../../deploy/atc-gateway/versions.env" > "$tree/release"
  release="$(< "$tree/release")"

  # shellcheck disable=SC2016 # expanded by the inner shell
  env -i PATH="$tree/bin:$PATH" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash -c 'source "$1"; with_fixture_images touch "$2/ran"' _ \
    "$(dirname "${BASH_SOURCE[0]}")/with-fixture-images.sh" "$tree" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/gh-env" <<< 'GH_TELEMETRY=0 DO_NOT_TRACK=1 GH_NO_UPDATE_NOTIFIER=1'
  # the fetch downloads into its own mktemp directory under TMPDIR, so that path is masked
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|WORK|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" <<< "[\"gh\",\"release\",\"download\",\"$release\",\"-R\",\"zgeoff/atc\",\"-p\",\"atc-gateway-linux-x64\",\"-p\",\"SHA256SUMS\",\"-D\",\"WORK\"]"
  diff - "$tree/out" << 'EOF'
FAIL the images did not build from the pinned, checked binary and pinned bases
    release not found
EOF
  diff /dev/null "$tree/err"
  [ ! -e "$tree/ran" ] || { echo "the command ran after a failed build" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

run_cases
