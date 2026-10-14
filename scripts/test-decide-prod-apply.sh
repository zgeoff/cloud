#!/usr/bin/env bash
# Test for decide-prod-apply.sh: against a real git repository in the case tree, with origin/main
# and the deployed/prod tag set by each case, and a gh stand-in for find-ci-run.sh
# (test-support/shell/create-stub-ci-runs-gh.sh), it decides whether a CI run's commit or a
# dispatched main tip needs the prod apply, writes the decision to the step output file, says in
# the step summary when nothing applies, and refuses a dispatch off main's tip, a dispatch with
# no green CI run, a commit off main, a missing tag and a tag that has left main. Each case runs
# the script under `env -i` with git's global and system config off, and compares its whole
# stdout, stderr, step output, step summary and gh call log.
#
# The script's "unexpected decision" guard stays untested: needs-prod-apply.sh prints only true
# or false, or fails, so no real state reaches it.
#
#   bash scripts/test-decide-prod-apply.sh
#   CASE='dispatch' bash scripts/test-decide-prod-apply.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-ci-runs-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decide-prod-apply.sh"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
# system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_decides_an_apply_of_the_ci_run_s_commit_when_it_changes_a_pulumi_input() {
  local head status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  mkdir "$tree/repo/infra"
  echo 'export {};' > "$tree/repo/infra/index.ts"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'change the program'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION= \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/output" << EOF
apply=true
revision=$head
EOF
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_decides_no_apply_and_says_so_when_no_pulumi_input_changed() {
  local head status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  mkdir "$tree/repo/docs"
  echo 'notes' > "$tree/repo/docs/notes.md"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'change the docs'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'No Pulumi input changed since deployed/prod, so nothing applied.'
  diff /dev/null "$tree/err"
  diff - "$tree/output" << EOF
apply=false
revision=$head
EOF
  diff - "$tree/summary" <<< 'No Pulumi input changed since deployed/prod, so nothing applied.'
  diff /dev/null "$tree/calls"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_applies_main_s_tip_on_a_dispatch_after_a_green_ci_run_on_it() {
  local head status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  mkdir "$tree/repo/deploy"
  echo 'kind: Job' > "$tree/repo/deploy/job.yaml"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'change a manifest'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    STUB_RUNS='https://github.com/zgeoff/cloud/actions/runs/7' \
    EVENT=workflow_dispatch RUN_HEAD= DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "CI passed on $head: https://github.com/zgeoff/cloud/actions/runs/7"
  diff /dev/null "$tree/err"
  diff - "$tree/output" << EOF
apply=true
revision=$head
EOF
  diff /dev/null "$tree/summary"
  diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$head\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$head\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_refuses_a_dispatch_on_a_branch_other_than_main() {
  local head status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    STUB_RUNS='https://github.com/zgeoff/cloud/actions/runs/7' \
    EVENT=workflow_dispatch DISPATCH_REF=refs/heads/feature DISPATCH_SHA="$head" DISPATCH_REVISION="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "a dispatch applies main's tip only: dispatch on main with revision $head"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_a_dispatch_whose_revision_is_not_main_s_tip() {
  local head older status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  older="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" commit -q --allow-empty -m 'move main on'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    STUB_RUNS='https://github.com/zgeoff/cloud/actions/runs/7' \
    EVENT=workflow_dispatch DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION="$older" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "a dispatch applies main's tip only: dispatch on main with revision $head"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_a_dispatch_with_no_green_ci_run_on_main_s_tip() {
  local head status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  git -C "$tree/repo" commit -q --allow-empty -m 'move main on'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_dispatch DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "no green CI run of a push to main on $head: wait for CI to pass"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$head\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$head\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_with_gh_s_error_and_exit_when_the_ci_run_lookup_fails() {
  local head status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  git -C "$tree/repo" commit -q --allow-empty -m 'move main on'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    STUB_GH_ERROR='To get started with GitHub CLI, please run:  gh auth login' STUB_GH_EXIT=4 \
    EVENT=workflow_dispatch DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'To get started with GitHub CLI, please run:  gh auth login'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$head\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$head\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
  [ "$status" = 4 ] || {
    echo "exit $status, want 4" >&2
    exit 1
  }
}

it_refuses_a_ci_run_s_commit_that_is_not_on_main() {
  local side status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD
  git -C "$tree/repo" checkout -q -b side
  git -C "$tree/repo" commit -q --allow-empty -m 'a commit off main'
  side="$(git -C "$tree/repo" rev-parse HEAD)"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$side" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$side is not on main"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_with_git_s_error_when_the_deployed_prod_tag_is_missing() {
  local head status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'fatal: Needed a single revision'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  [ "$status" = 128 ] || {
    echo "exit $status, want 128" >&2
    exit 1
  }
}

it_fails_with_needs_prod_apply_s_error_when_the_tag_has_left_main() {
  local deployed head status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" checkout -q -b side
  git -C "$tree/repo" commit -q --allow-empty -m 'a commit off main'
  git -C "$tree/repo" tag deployed/prod
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" checkout -q main
  git -C "$tree/repo" commit -q --allow-empty -m 'move main on'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "needs-prod-apply: $deployed is not an ancestor of $head; set the tag by hand at the live revision"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_to_run_without_the_step_output_file() {
  local head status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'decide-prod-apply: set GITHUB_OUTPUT'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  : > "$tree/output"
  : > "$tree/summary"
  create_stub_ci_runs_gh "$tree/bin"
  git -C "$tree/repo" init -q -b main
  # boot data: an empty root commit, so HEAD resolves
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
