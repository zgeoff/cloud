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

# GH_HOST points gh at a dead loopback port, so the release fetch fails at once with Go's
# own connection error and nothing leaves the machine. gh sends its release lookup and a
# GraphQL query at once and reports whichever fails first, so the log is one of exactly
# two lines. The lookup's URL carries the pinned release tag with its slash escaped, as gh
# escapes it, so the case reads the tag from the pins.
it_reports_a_failed_build_with_its_log_and_runs_nothing() {
  local release status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree" || true' EXIT
  mkdir "$tree/gh" "$tree/home" "$tree/tmp"
  sed -n 's/^ATC_RELEASE=//p' "$(dirname "${BASH_SOURCE[0]}")/../../deploy/atc-gateway/versions.env" > "$tree/release"
  release="$(< "$tree/release")"

  # shellcheck disable=SC2016 # expanded by the inner shell
  env -i PATH="$PATH" HOME="$tree/home" TMPDIR="$tree/tmp" GH_HOST=127.0.0.1:1 GH_CONFIG_DIR="$tree/gh" \
    bash -c 'source "$1"; with_fixture_images touch "$2/ran"' _ \
    "$(dirname "${BASH_SOURCE[0]}")/with-fixture-images.sh" "$tree" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  cat > "$tree/want-lookup" << EOF
FAIL the images did not build from the pinned, checked binary and pinned bases
    Get "https://127.0.0.1:1/api/v3/repos/zgeoff/atc/releases/tags/${release//\//%2F}": dial tcp 127.0.0.1:1: connect: connection refused
EOF
  cat > "$tree/want-graphql" << 'EOF'
FAIL the images did not build from the pinned, checked binary and pinned bases
    Post "https://127.0.0.1:1/api/graphql": dial tcp 127.0.0.1:1: connect: connection refused
EOF
  cmp -s "$tree/want-lookup" "$tree/out" || cmp -s "$tree/want-graphql" "$tree/out" ||
    { diff "$tree/want-lookup" "$tree/out" || diff "$tree/want-graphql" "$tree/out"; exit 1; }
  [ ! -e "$tree/ran" ] || { echo "the command ran after a failed build" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

run_cases
