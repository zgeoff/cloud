#!/usr/bin/env bash
# Test for decide-prod-apply.sh: against a real git repository in the case tree, with origin/main
# and the deployed/prod tag set by each case, and a gh stand-in for find-ci-run.sh
# (test-support/shell/create-stub-gh.sh) that replays the runs each case records, it decides
# whether a CI run's commit or a dispatched main tip needs the prod apply, each of two merges that
# land minutes apart and a commit that a newer apply already deployed included, writes the decision
# and the tag's commit to the step output file, says in the step summary when nothing applies, and
# refuses a dispatch off main's tip, a dispatch with no green CI
# run, a commit off main, a missing tag and a tag that has left main. Each case runs
# the script under `env -i` with git's global and system config off, and compares its whole
# stdout, stderr, step output, step summary and gh call log.
#
# The script's "unexpected decision" guard stays untested: run-decide-gates.ts prints only
# prod-apply=true or prod-apply=false, or fails, so no real state reaches it. Each case links the
# real bun into its stand-ins' directory, because the script runs run-decide-gates.ts with it.
#
#   bash scripts/test-decide-prod-apply.sh
#   CASE='dispatch' bash scripts/test-decide-prod-apply.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decide-prod-apply.sh"
bun="$(command -v bun)"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
# system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_decides_an_apply_of_the_ci_run_s_commit_when_it_changes_a_pulumi_input() {
  local deployed head status=0
  create_case_tree
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  mkdir "$tree/repo/infra"
  echo 'export {};' > "$tree/repo/infra/index.ts"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'change the program'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION= \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/output" << EOF
apply=true
revision=$head
deployed=$deployed
EOF
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  assert_status 0 "$status"
}

it_decides_no_apply_and_says_so_when_no_pulumi_input_changed() {
  local deployed head status=0
  create_case_tree
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  mkdir "$tree/repo/docs"
  echo 'notes' > "$tree/repo/docs/notes.md"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'change the docs'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "No commit after deployed/prod at $deployed up to $head changes a Pulumi input, so nothing applied."
  diff /dev/null "$tree/err"
  diff - "$tree/output" << EOF
apply=false
revision=$head
deployed=$deployed
EOF
  diff - "$tree/summary" <<< "No commit after deployed/prod at $deployed up to $head changes a Pulumi input, so nothing applied."
  diff /dev/null "$tree/calls"
  assert_status 0 "$status"
}

# In the next two cases, two merges land minutes apart: the first changes only the host (nixos/),
# the second bumps a pin in infra/Pulumi.prod.yaml. Each merge's CI run starts its own Deploy prod
# run. GitHub gives both runs main's tip, the second merge, as their own head commit
# (DISPATCH_SHA), and RUN_HEAD is the commit each CI run checked.
it_decides_an_apply_of_a_pin_bump_that_merges_minutes_after_a_merge_with_no_pulumi_input() {
  local deployed bump status=0
  create_case_tree
  setup_test "$tree"
  mkdir "$tree/repo/infra" "$tree/repo/nixos"
  echo 'example:imageTag: 1.0.0' > "$tree/repo/infra/Pulumi.prod.yaml"
  echo '{ version = "1.0.0"; }' > "$tree/repo/nixos/agent.nix"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the program and the host'
  git -C "$tree/repo" tag deployed/prod
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  echo '{ version = "2.0.0"; }' > "$tree/repo/nixos/agent.nix"
  git -C "$tree/repo" commit -qam 'bump the host agent'
  echo 'example:imageTag: 1.1.0' > "$tree/repo/infra/Pulumi.prod.yaml"
  git -C "$tree/repo" commit -qam 'bump the image pin'
  bump="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$bump" DISPATCH_REF=refs/heads/main DISPATCH_SHA="$bump" DISPATCH_REVISION= \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/output" << EOF
apply=true
revision=$bump
deployed=$deployed
EOF
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  assert_status 0 "$status"
}

it_decides_no_apply_for_the_earlier_merge_s_run_and_names_its_commit_while_main_holds_the_pin_bump() {
  local deployed host bump status=0
  create_case_tree
  setup_test "$tree"
  mkdir "$tree/repo/infra" "$tree/repo/nixos"
  echo 'example:imageTag: 1.0.0' > "$tree/repo/infra/Pulumi.prod.yaml"
  echo '{ version = "1.0.0"; }' > "$tree/repo/nixos/agent.nix"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the program and the host'
  git -C "$tree/repo" tag deployed/prod
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  echo '{ version = "2.0.0"; }' > "$tree/repo/nixos/agent.nix"
  git -C "$tree/repo" commit -qam 'bump the host agent'
  host="$(git -C "$tree/repo" rev-parse HEAD)"
  echo 'example:imageTag: 1.1.0' > "$tree/repo/infra/Pulumi.prod.yaml"
  git -C "$tree/repo" commit -qam 'bump the image pin'
  bump="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$host" DISPATCH_REF=refs/heads/main DISPATCH_SHA="$bump" DISPATCH_REVISION= \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "No commit after deployed/prod at $deployed up to $host changes a Pulumi input, so nothing applied."
  diff /dev/null "$tree/err"
  diff - "$tree/output" << EOF
apply=false
revision=$host
deployed=$deployed
EOF
  diff - "$tree/summary" <<< "No commit after deployed/prod at $deployed up to $host changes a Pulumi input, so nothing applied."
  diff /dev/null "$tree/calls"
  assert_status 0 "$status"
}

it_decides_no_apply_and_says_so_when_a_newer_apply_moved_the_tag_past_the_revision() {
  local deployed revision status=0
  create_case_tree
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
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$revision" DISPATCH_REF=refs/heads/main DISPATCH_SHA="$deployed" DISPATCH_REVISION= \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "deployed/prod at $deployed already holds every Pulumi input of $revision, so nothing applied."
  diff /dev/null "$tree/err"
  diff - "$tree/output" << EOF
apply=false
revision=$revision
deployed=$deployed
EOF
  diff - "$tree/summary" <<< "deployed/prod at $deployed already holds every Pulumi input of $revision, so nothing applied."
  diff /dev/null "$tree/calls"
  assert_status 0 "$status"
}

it_applies_main_s_tip_on_a_dispatch_after_a_green_ci_run_on_it() {
  local deployed head status=0
  create_case_tree
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  mkdir "$tree/repo/deploy"
  echo 'kind: Job' > "$tree/repo/deploy/job.yaml"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'change a manifest'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD
  # the lines find-ci-run.sh's --jq filter prints: one run URL per green run
  jq -cn --arg head "$head" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "head_sha=\($head)", "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.head_sha == \"\($head)\" and .event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .html_url"],
    stdout: "https://github.com/zgeoff/cloud/actions/runs/7\n"}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_dispatch RUN_HEAD= DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "CI passed on $head: https://github.com/zgeoff/cloud/actions/runs/7"
  diff /dev/null "$tree/err"
  diff - "$tree/output" << EOF
apply=true
revision=$head
deployed=$deployed
EOF
  diff /dev/null "$tree/summary"
  diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$head\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$head\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
  assert_status 0 "$status"
}

it_refuses_a_dispatch_on_a_branch_other_than_main() {
  local head status=0
  create_case_tree
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD
  # a green run on the commit, so only the branch refuses the dispatch
  jq -cn --arg head "$head" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "head_sha=\($head)", "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.head_sha == \"\($head)\" and .event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .html_url"],
    stdout: "https://github.com/zgeoff/cloud/actions/runs/7\n"}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_dispatch DISPATCH_REF=refs/heads/feature DISPATCH_SHA="$head" DISPATCH_REVISION="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "a dispatch applies main's tip only: dispatch on main with revision $head"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_refuses_a_dispatch_whose_revision_is_not_main_s_tip() {
  local head older status=0
  create_case_tree
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  older="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" commit -q --allow-empty -m 'move main on'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD
  # a green run on the tip, so only the revision refuses the dispatch
  jq -cn --arg head "$head" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "head_sha=\($head)", "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.head_sha == \"\($head)\" and .event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .html_url"],
    stdout: "https://github.com/zgeoff/cloud/actions/runs/7\n"}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_dispatch DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION="$older" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "a dispatch applies main's tip only: dispatch on main with revision $head"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_refuses_a_dispatch_with_no_green_ci_run_on_main_s_tip() {
  local head status=0
  create_case_tree
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  git -C "$tree/repo" commit -q --allow-empty -m 'move main on'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD
  # no green run: the --jq filter prints nothing
  jq -cn --arg head "$head" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "head_sha=\($head)", "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.head_sha == \"\($head)\" and .event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .html_url"]}' \
    > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_dispatch DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "no green CI run of a push to main on $head: wait for CI to pass"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$head\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$head\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
  assert_status 1 "$status"
}

it_fails_with_gh_s_error_and_exit_when_the_ci_run_lookup_fails() {
  local head status=0
  create_case_tree
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  git -C "$tree/repo" commit -q --allow-empty -m 'move main on'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 4 when gh needs
  # authentication
  jq -cn --arg head "$head" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "head_sha=\($head)", "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.head_sha == \"\($head)\" and .event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .html_url"],
    stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exit: 4}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_dispatch DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'To get started with GitHub CLI, please run:  gh auth login'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$head\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$head\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
  assert_status 4 "$status"
}

it_refuses_a_ci_run_s_commit_that_is_not_on_main() {
  local side status=0
  create_case_tree
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD
  git -C "$tree/repo" checkout -q -b side
  git -C "$tree/repo" commit -q --allow-empty -m 'a commit off main'
  side="$(git -C "$tree/repo" rev-parse HEAD)"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$side" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$side is not on main"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_fails_with_git_s_error_when_the_deployed_prod_tag_is_missing() {
  local head status=0
  create_case_tree
  setup_test "$tree"
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'fatal: Needed a single revision'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  assert_status 128 "$status"
}

it_refuses_a_tag_that_has_left_main() {
  local deployed head status=0
  create_case_tree
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
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "decide-prod-apply: deployed/prod at $deployed is not an ancestor of $head; set the tag by hand at the live revision"
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_refuses_to_run_without_the_step_output_file() {
  local head status=0
  create_case_tree
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'decide-prod-apply: set GITHUB_OUTPUT'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  : > "$tree/output"
  : > "$tree/summary"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
  ln -s "$bun" "$tree/bin/bun"
  git -C "$tree/repo" init -q -b main
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # the case's trap removes it
  git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
