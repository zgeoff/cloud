#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for decide-prod-apply.sh: against a real git repository in the case tree, with origin/main
# and the deployed/prod tag set by each case, and a gh stand-in for find-ci-run.sh
# (scripts/src/test-utils/shell/create-stub-gh.sh) that replays the runs each case records, it decides
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
#   bash scripts/run-bats.sh
#   CASE='dispatch' bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-gh.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/decide-prod-apply.sh"
  bun="$(command -v bun)"
  # The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
  # system setting from the caller's environment, and commit as a fixed identity.
  while read -r name; do unset "$name"; done < <(compgen -e GIT_)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
    GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
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
  # bats removes the case tree
  git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

@test "it decides an apply of the ci run s commit when it changes a pulumi input" {
  local deployed head
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  mkdir "$tree/repo/infra"
  echo 'export {};' > "$tree/repo/infra/index.ts"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'change the program'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION= \
    bash "$script"

  refute_output
  refute_stderr

  run -0 diff - "$tree/output" << EOF
apply=true
revision=$head
deployed=$deployed
EOF
  run -0 diff /dev/null "$tree/summary"
  run -0 diff /dev/null "$tree/calls"
}

@test "it decides no apply and says so when no pulumi input changed" {
  local deployed head
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  mkdir "$tree/repo/docs"
  echo 'notes' > "$tree/repo/docs/notes.md"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'change the docs'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" \
    bash "$script"

  assert_output "No commit after deployed/prod at $deployed up to $head changes a Pulumi input, so nothing applied."
  refute_stderr

  run -0 diff - "$tree/output" << EOF
apply=false
revision=$head
deployed=$deployed
EOF
  run -0 diff - "$tree/summary" <<< "No commit after deployed/prod at $deployed up to $head changes a Pulumi input, so nothing applied."
  run -0 diff /dev/null "$tree/calls"
}

# In the next two cases, two merges land minutes apart: the first changes only the host (nixos/),
# the second bumps a pin in infra/Pulumi.prod.yaml. Each merge's CI run starts its own Deploy prod
# run. GitHub gives both runs main's tip, the second merge, as their own head commit
# (DISPATCH_SHA), and RUN_HEAD is the commit each CI run checked.
@test "it decides an apply of a pin bump that merges minutes after a merge with no pulumi input" {
  local deployed bump
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

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$bump" DISPATCH_REF=refs/heads/main DISPATCH_SHA="$bump" DISPATCH_REVISION= \
    bash "$script"

  refute_output
  refute_stderr

  run -0 diff - "$tree/output" << EOF
apply=true
revision=$bump
deployed=$deployed
EOF
  run -0 diff /dev/null "$tree/summary"
  run -0 diff /dev/null "$tree/calls"
}

@test "it decides no apply for the earlier merge s run and names its commit while main holds the pin bump" {
  local deployed host bump
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

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$host" DISPATCH_REF=refs/heads/main DISPATCH_SHA="$bump" DISPATCH_REVISION= \
    bash "$script"

  assert_output "No commit after deployed/prod at $deployed up to $host changes a Pulumi input, so nothing applied."
  refute_stderr

  run -0 diff - "$tree/output" << EOF
apply=false
revision=$host
deployed=$deployed
EOF
  run -0 diff - "$tree/summary" <<< "No commit after deployed/prod at $deployed up to $host changes a Pulumi input, so nothing applied."
  run -0 diff /dev/null "$tree/calls"
}

@test "it decides no apply and says so when a newer apply moved the tag past the revision" {
  local deployed revision
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

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$revision" DISPATCH_REF=refs/heads/main DISPATCH_SHA="$deployed" DISPATCH_REVISION= \
    bash "$script"

  assert_output "deployed/prod at $deployed already holds every Pulumi input of $revision, so nothing applied."
  refute_stderr

  run -0 diff - "$tree/output" << EOF
apply=false
revision=$revision
deployed=$deployed
EOF
  run -0 diff - "$tree/summary" <<< "deployed/prod at $deployed already holds every Pulumi input of $revision, so nothing applied."
  run -0 diff /dev/null "$tree/calls"
}

@test "it applies main s tip on a dispatch after a green ci run on it" {
  local deployed head
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

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_dispatch RUN_HEAD= DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION="$head" \
    bash "$script"

  assert_output "CI passed on $head: https://github.com/zgeoff/cloud/actions/runs/7"
  refute_stderr

  run -0 diff - "$tree/output" << EOF
apply=true
revision=$head
deployed=$deployed
EOF
  run -0 diff /dev/null "$tree/summary"
  run -0 diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$head\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$head\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
}

@test "it refuses a dispatch on a branch other than main" {
  local head
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD
  # a green run on the commit, so only the branch refuses the dispatch
  jq -cn --arg head "$head" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "head_sha=\($head)", "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.head_sha == \"\($head)\" and .event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .html_url"],
    stdout: "https://github.com/zgeoff/cloud/actions/runs/7\n"}' > "$tree/gh-responses"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_dispatch DISPATCH_REF=refs/heads/feature DISPATCH_SHA="$head" DISPATCH_REVISION="$head" \
    bash "$script"

  refute_output
  assert_stderr "a dispatch applies main's tip only: dispatch on main with revision $head"

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
  run -0 diff /dev/null "$tree/calls"
}

@test "it refuses a dispatch whose revision is not main s tip" {
  local head older
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

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_dispatch DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION="$older" \
    bash "$script"

  refute_output
  assert_stderr "a dispatch applies main's tip only: dispatch on main with revision $head"

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
  run -0 diff /dev/null "$tree/calls"
}

@test "it refuses a dispatch with no green ci run on main s tip" {
  local head
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

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_dispatch DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION="$head" \
    bash "$script"

  refute_output
  assert_stderr "no green CI run of a push to main on $head: wait for CI to pass"

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
  run -0 diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$head\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$head\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
}

@test "it fails with gh s error and exit when the ci run lookup fails" {
  local head
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

  run -4 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_dispatch DISPATCH_REF=refs/heads/main DISPATCH_SHA="$head" DISPATCH_REVISION="$head" \
    bash "$script"

  refute_output
  assert_stderr 'To get started with GitHub CLI, please run:  gh auth login'

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
  run -0 diff - "$tree/calls" <<< "[\"gh\",\"api\",\"-X\",\"GET\",\"repos/{owner}/{repo}/actions/workflows/ci.yml/runs\",\"-f\",\"head_sha=$head\",\"-f\",\"event=push\",\"-f\",\"branch=main\",\"-f\",\"status=success\",\"-f\",\"per_page=100\",\"--jq\",\".workflow_runs[] | select(.head_sha == \\\"$head\\\" and .event == \\\"push\\\" and .head_branch == \\\"main\\\" and .conclusion == \\\"success\\\") | .html_url\"]"
}

@test "it refuses a ci run s commit that is not on main" {
  local side
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD
  git -C "$tree/repo" checkout -q -b side
  git -C "$tree/repo" commit -q --allow-empty -m 'a commit off main'
  side="$(git -C "$tree/repo" rev-parse HEAD)"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$side" \
    bash "$script"

  refute_output
  assert_stderr "$side is not on main"

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
  run -0 diff /dev/null "$tree/calls"
}

@test "it fails with git s error when the deployed prod tag is missing" {
  local head
  setup_test "$tree"
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  run -128 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" \
    bash "$script"

  refute_output
  assert_stderr 'fatal: Needed a single revision'

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
  run -0 diff /dev/null "$tree/calls"
}

@test "it refuses a tag that has left main" {
  local deployed head
  setup_test "$tree"
  git -C "$tree/repo" checkout -q -b side
  git -C "$tree/repo" commit -q --allow-empty -m 'a commit off main'
  git -C "$tree/repo" tag deployed/prod
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" checkout -q main
  git -C "$tree/repo" commit -q --allow-empty -m 'move main on'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" \
    bash "$script"

  refute_output
  assert_stderr "decide-prod-apply: deployed/prod at $deployed is not an ancestor of $head; set the tag by hand at the live revision"

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
  run -0 diff /dev/null "$tree/calls"
}

@test "it refuses to run without the step output file" {
  local head
  setup_test "$tree"
  git -C "$tree/repo" tag deployed/prod
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  git -C "$tree/repo" update-ref refs/remotes/origin/main HEAD

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_STEP_SUMMARY="$tree/summary" \
    EVENT=workflow_run RUN_HEAD="$head" \
    bash "$script"

  refute_output
  assert_stderr 'decide-prod-apply: set GITHUB_OUTPUT'

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
  run -0 diff /dev/null "$tree/calls"
}
