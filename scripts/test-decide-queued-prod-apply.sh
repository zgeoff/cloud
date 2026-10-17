#!/usr/bin/env bash
# Test for decide-queued-prod-apply.sh: against a real git repository in the case tree, with the
# deployed/prod tag set by each case, it decides an apply of a revision that changes a Pulumi input
# since the tag as it stands, decides no apply and says so for a revision a newer apply already
# deployed, writes the decision and the tag's commit to the step output file, and refuses a
# missing tag, a tag that has left main and a missing variable. Each case runs the script under
# `env -i` with git's global and system config off, and compares its whole stdout, stderr, step
# output and step summary.
#
#   bash scripts/test-decide-queued-prod-apply.sh
#   CASE='newer apply' bash scripts/test-decide-queued-prod-apply.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decide-queued-prod-apply.sh"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
# system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_decides_an_apply_when_the_revision_changes_a_pulumi_input_since_the_tag() {
  local deployed revision status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" tag deployed/prod
  mkdir "$tree/repo/infra"
  echo 'export {};' > "$tree/repo/infra/index.ts"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'change the program'
  revision="$(git -C "$tree/repo" rev-parse HEAD)"

  (cd "$tree/repo" && env -i PATH="/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" REVISION="$revision" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/output" << EOF
apply=true
deployed=$deployed
EOF
  diff /dev/null "$tree/summary"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_decides_no_apply_and_says_so_when_a_newer_apply_moved_the_tag_past_the_revision() {
  local deployed revision status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/infra"
  echo 'export {};' > "$tree/repo/infra/index.ts"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'change the program'
  revision="$(git -C "$tree/repo" rev-parse HEAD)"
  echo 'export const name = "prod";' > "$tree/repo/infra/index.ts"
  git -C "$tree/repo" commit -qam 'change the program again'
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" tag deployed/prod

  (cd "$tree/repo" && env -i PATH="/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" REVISION="$revision" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "deployed/prod at $deployed already holds every Pulumi input of $revision, so nothing applied."
  diff /dev/null "$tree/err"
  diff - "$tree/output" << EOF
apply=false
deployed=$deployed
EOF
  diff - "$tree/summary" <<< "deployed/prod at $deployed already holds every Pulumi input of $revision, so nothing applied."
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_with_git_s_error_when_the_deployed_prod_tag_is_missing() {
  local revision status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  revision="$(git -C "$tree/repo" rev-parse HEAD)"

  (cd "$tree/repo" && env -i PATH="/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" REVISION="$revision" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'fatal: Needed a single revision'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  [ "$status" = 128 ] || {
    echo "exit $status, want 128" >&2
    exit 1
  }
}

it_fails_with_needs_prod_apply_s_error_when_the_tag_has_left_main() {
  local deployed revision status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" checkout -q -b side
  git -C "$tree/repo" commit -q --allow-empty -m 'a commit off main'
  git -C "$tree/repo" tag deployed/prod
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" checkout -q main
  git -C "$tree/repo" commit -q --allow-empty -m 'move main on'
  revision="$(git -C "$tree/repo" rev-parse HEAD)"

  (cd "$tree/repo" && env -i PATH="/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" REVISION="$revision" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "needs-prod-apply: $deployed is not an ancestor of $revision; set the tag by hand at the live revision"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_a_missing_revision_as_a_usage_error() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod

  (cd "$tree/repo" && env -i PATH="/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" REVISION= \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'decide-queued-prod-apply: set REVISION'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/output"
  : > "$tree/summary"
  git -C "$tree/repo" init -q -b main
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # the case's trap removes it
  git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
