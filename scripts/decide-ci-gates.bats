#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Each case links the real bun into its stand-ins' directory, because the script runs
# run-decide-gates.ts with it, which reads the real .github/gates.yml.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-gh.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/decide-ci-gates.sh"
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

# Runtime every case needs: the gh stand-in, the real bun, empty GitHub files, and an empty git
# repository.
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
}

@test "it checks a cancelled push s provider change on a later docs only push" {
  local green
  setup_test "$tree"
  echo '# lantern' > "$tree/repo/README.md"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the lantern readme'
  green="$(git -C "$tree/repo" rev-parse HEAD)"
  mkdir "$tree/repo/provider"
  echo 'package main' > "$tree/repo/provider/main.go"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the lantern provider'
  echo '# lantern, tuned' > "$tree/repo/README.md"
  git -C "$tree/repo" commit -qam 'tune the lantern readme'
  # the provider commit's run was cancelled, so only the first commit's run is green; no pull
  # request run left a record of this tree on the green commit's tree
  {
    jq -cn --arg stdout "$green
" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
      "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"],
      stdout: $stdout}'
    jq -cn '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/artifacts", "-f", null,
      "-f", "per_page=100", "--jq",
      "[.artifacts[] | select(.expired == false and .workflow_run.head_repository_id == .workflow_run.repository_id)][0].workflow_run.id // empty"]}'
  } > "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=zgeoff/cloud \
    EVENT=push HEAD="$(git -C "$tree/repo" rev-parse HEAD)" \
    bash "$script" provider full

  assert_output 'provider=true
full=true'
  refute_stderr

  run -0 diff - "$tree/output" <<< 'provider=true
full=true'
  run -0 diff /dev/null "$tree/summary"
  run -0 diff - "$tree/calls" << EOF
["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/ci.yml/runs","-f","event=push","-f","branch=main","-f","status=success","-f","per_page=100","--jq",".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"]
["gh","api","-X","GET","repos/{owner}/{repo}/actions/artifacts","-f","name=ci-pass-$(git -C "$tree/repo" rev-parse 'HEAD^{tree}')-$(git -C "$tree/repo" rev-parse "$green^{tree}")","-f","per_page=100","--jq","[.artifacts[] | select(.expired == false and .workflow_run.head_repository_id == .workflow_run.repository_id)][0].workflow_run.id // empty"]
EOF
}

@test "it skips every check of a push whose trees a green pull request run checked" {
  local base head
  setup_test "$tree"
  echo '# lantern' > "$tree/repo/README.md"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the lantern readme'
  base="$(git -C "$tree/repo" rev-parse HEAD)"
  mkdir "$tree/repo/provider"
  echo 'package main' > "$tree/repo/provider/main.go"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the lantern provider'
  head="$(git -C "$tree/repo" rev-parse HEAD)"
  # GitHub's REST docs (actions/artifacts, list artifacts for a repository, read 2026-10-28): the
  # artifact's workflow_run holds the id of the run that uploaded it
  {
    jq -cn --arg stdout "$base
" '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
      "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
      "--jq", ".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"],
      stdout: $stdout}'
    jq -cn --arg name "name=ci-pass-$(git -C "$tree/repo" rev-parse "$head^{tree}")-$(git -C "$tree/repo" rev-parse "$base^{tree}")" \
      '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/artifacts", "-f", $name,
      "-f", "per_page=100", "--jq",
      "[.artifacts[] | select(.expired == false and .workflow_run.head_repository_id == .workflow_run.repository_id)][0].workflow_run.id // empty"],
      stdout: "5150\n"}'
  } > "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=zgeoff/cloud \
    EVENT=push HEAD="$head" \
    bash "$script" provider full

  assert_output - << 'EOF'
provider=false
full=false
reused=true
Pull request run https://github.com/zgeoff/cloud/actions/runs/5150 passed this tree on the same base tree, so the checks did not run again.
EOF
  refute_stderr

  run -0 diff - "$tree/output" << 'EOF'
provider=false
full=false
reused=true
EOF
  run -0 diff - "$tree/summary" <<< 'Pull request run https://github.com/zgeoff/cloud/actions/runs/5150 passed this tree on the same base tree, so the checks did not run again.'
}

@test "it asks for no record on a push with no green base" {
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'add the lantern service'
  # no green main run: the --jq filter prints nothing
  jq -cn '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"]}' \
    > "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" EVENT=push HEAD="$(git -C "$tree/repo" rev-parse HEAD)" \
    bash "$script" provider full

  assert_output 'provider=true
full=true'
  refute_stderr

  run -0 diff - "$tree/calls" <<< '["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/ci.yml/runs","-f","event=push","-f","branch=main","-f","status=success","-f","per_page=100","--jq",".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"]'
}

@test "it compares a pull request with its base" {
  local base
  setup_test "$tree"
  mkdir "$tree/repo/provider"
  echo 'package main' > "$tree/repo/provider/main.go"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the lantern provider'
  base="$(git -C "$tree/repo" rev-parse HEAD)"
  echo '# lantern' > "$tree/repo/README.md"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the lantern readme'

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" EVENT=pull_request PR_BASE="$base" \
    HEAD="$(git -C "$tree/repo" rev-parse HEAD)" \
    bash "$script" provider full

  assert_output 'provider=false
full=false
No input of the provider checks changed, so the Go checks did not run.
Only Markdown files changed, so the Nix-image linters and the shell suites did not run.'
  refute_stderr

  run -0 diff - "$tree/output" <<< 'provider=false
full=false'
  run -0 diff - "$tree/summary" <<< 'No input of the provider checks changed, so the Go checks did not run.
Only Markdown files changed, so the Nix-image linters and the shell suites did not run.'
  run -0 diff /dev/null "$tree/calls"
}

@test "it fails with gh error and exit when the base lookup fails" {
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'add the lantern service'
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 4 when gh needs
  # authentication
  jq -cn '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/workflows/ci.yml/runs",
    "-f", "event=push", "-f", "branch=main", "-f", "status=success", "-f", "per_page=100",
    "--jq", ".workflow_runs[] | select(.event == \"push\" and .head_branch == \"main\" and .conclusion == \"success\") | .head_sha"],
    stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exit: 4}' > "$tree/gh-responses"

  run -4 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" EVENT=push HEAD="$(git -C "$tree/repo" rev-parse HEAD)" \
    bash "$script" provider full

  refute_output
  assert_stderr 'To get started with GitHub CLI, please run:  gh auth login'

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/summary"
}

@test "it rejects a pull request without its base with its usage" {
  setup_test "$tree"
  git -C "$tree/repo" commit -q --allow-empty -m 'add the lantern service'

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_OUTPUT="$tree/output" \
    GITHUB_STEP_SUMMARY="$tree/summary" EVENT=pull_request \
    HEAD="$(git -C "$tree/repo" rev-parse HEAD)" \
    bash "$script" provider full

  refute_output
  assert_stderr 'usage: EVENT=<event> HEAD=<commit> [PR_BASE=<commit>] decide-ci-gates.sh <gate>...'

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/calls"
}
