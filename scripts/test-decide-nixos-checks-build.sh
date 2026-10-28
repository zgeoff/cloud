#!/usr/bin/env bash
# Test for decide-nixos-checks-build.sh: against a real git repository in the case tree and a gh
# stand-in (test-support/shell/create-stub-gh.sh) that replays the artifact search each case
# records, as the line its --jq filter prints (the id of the run that uploaded the artifact), it
# writes the key and needed=false with the run's URL when a run built the same derivations,
# needed=true when none did or when a dispatch forces the build, gives the same derivations the
# same key unless a file that decides the build differs, and fails with gh's error and writes
# nothing when gh fails. Each case runs the script under `env -i` with git's global and system
# config off, and compares its whole stdout, stderr, GITHUB_OUTPUT, step summary and gh call log;
# the key is masked as KEY after a check of its form, because it is a hash.
#
#   bash scripts/test-decide-nixos-checks-build.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-not-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decide-nixos-checks-build.sh"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
# system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_skips_the_build_and_names_the_run_that_built_the_same_derivations() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-atc-daemon.drv\n' > "$tree/derivations"
  # the artifacts endpoint of GitHub's REST docs (actions/artifacts, list artifacts for a
  # repository, read 2026-10-28), filtered to the id of the run that uploaded the first match
  jq -cn '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/artifacts", "-f", null,
    "-f", "per_page=100", "--jq",
    "[.artifacts[] | select(.expired == false and .workflow_run.head_repository_id == .workflow_run.repository_id)][0].workflow_run.id // empty"],
    stdout: "4242\n"}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=zgeoff/cloud \
    bash "$script" "$tree/derivations") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'Run https://github.com/zgeoff/cloud/actions/runs/4242 built and passed these checks'"'"' derivations, so the checks did not run.'
  diff /dev/null "$tree/err"
  grep -qE '^key=[0-9a-f]{64}$' "$tree/output"
  sed -E 's/^key=[0-9a-f]{64}$/key=KEY/' "$tree/output" > "$tree/output-masked"
  diff - "$tree/output-masked" << 'EOF'
key=KEY
needed=false
EOF
  diff - "$tree/summary" <<< 'Run https://github.com/zgeoff/cloud/actions/runs/4242 built and passed these checks'"'"' derivations, so the checks did not run.'
  sed -E 's/name=nixos-checks-[0-9a-f]{64}/name=nixos-checks-KEY/' "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << 'EOF'
["gh","api","-X","GET","repos/{owner}/{repo}/actions/artifacts","-f","name=nixos-checks-KEY","-f","per_page=100","--jq","[.artifacts[] | select(.expired == false and .workflow_run.head_repository_id == .workflow_run.repository_id)][0].workflow_run.id // empty"]
EOF
  assert_status 0 "$status"
}

it_needs_the_build_when_no_run_built_the_same_derivations() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-atc-daemon.drv\n' > "$tree/derivations"
  # no artifact holds the name: the --jq filter prints nothing
  jq -cn '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/artifacts", "-f", null,
    "-f", "per_page=100", "--jq",
    "[.artifacts[] | select(.expired == false and .workflow_run.head_repository_id == .workflow_run.repository_id)][0].workflow_run.id // empty"]}' \
    > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=zgeoff/cloud \
    bash "$script" "$tree/derivations") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  sed -E 's/^key=[0-9a-f]{64}$/key=KEY/' "$tree/output" > "$tree/output-masked"
  diff - "$tree/output-masked" << 'EOF'
key=KEY
needed=true
EOF
  diff /dev/null "$tree/summary"
  sed -E 's/name=nixos-checks-[0-9a-f]{64}/name=nixos-checks-KEY/' "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << 'EOF'
["gh","api","-X","GET","repos/{owner}/{repo}/actions/artifacts","-f","name=nixos-checks-KEY","-f","per_page=100","--jq","[.artifacts[] | select(.expired == false and .workflow_run.head_repository_id == .workflow_run.repository_id)][0].workflow_run.id // empty"]
EOF
  assert_status 0 "$status"
}

it_needs_the_build_without_asking_gh_when_a_dispatch_forces_it() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-atc-daemon.drv\n' > "$tree/derivations"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FORCE=true \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=zgeoff/cloud \
    bash "$script" "$tree/derivations") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  sed -E 's/^key=[0-9a-f]{64}$/key=KEY/' "$tree/output" > "$tree/output-masked"
  diff - "$tree/output-masked" << 'EOF'
key=KEY
needed=true
EOF
  diff /dev/null "$tree/calls"
  assert_status 0 "$status"
}

it_keys_the_same_derivations_alike_when_only_a_file_outside_the_build_differs() {
  local first second commit
  create_case_tree
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-atc-daemon.drv\n' > "$tree/derivations"
  first="$(git -C "$tree/repo" rev-parse HEAD)"
  echo '# lantern' > "$tree/repo/README.md"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the lantern readme'
  second="$(git -C "$tree/repo" rev-parse HEAD)"

  for commit in "$first" "$second"; do
    git -C "$tree/repo" checkout -q "$commit"
    (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FORCE=true \
      GITHUB_OUTPUT="$tree/output-$commit" GITHUB_STEP_SUMMARY="$tree/summary" \
      GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=zgeoff/cloud \
      bash "$script" "$tree/derivations")
  done

  assert_equals "$(head -1 "$tree/output-$first")" "$(head -1 "$tree/output-$second")" 'second key'
}

it_keys_the_same_derivations_apart_when_a_build_script_differs() {
  local first second commit
  create_case_tree
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-atc-daemon.drv\n' > "$tree/derivations"
  first="$(git -C "$tree/repo" rev-parse HEAD)"
  echo 'echo two builds at once' >> "$tree/repo/scripts/run-nixos-checks.sh"
  git -C "$tree/repo" commit -qam 'change the build'
  second="$(git -C "$tree/repo" rev-parse HEAD)"

  for commit in "$first" "$second"; do
    git -C "$tree/repo" checkout -q "$commit"
    (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FORCE=true \
      GITHUB_OUTPUT="$tree/output-$commit" GITHUB_STEP_SUMMARY="$tree/summary" \
      GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=zgeoff/cloud \
      bash "$script" "$tree/derivations")
  done

  assert_not_equals "$(head -1 "$tree/output-$first")" "$(head -1 "$tree/output-$second")" 'second key'
}

it_keys_other_derivations_apart() {
  local list
  create_case_tree
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-atc-daemon.drv\n' > "$tree/derivations-a"
  printf '/nix/store/11111111111111111111111111111111-atc-daemon.drv\n' > "$tree/derivations-b"

  for list in a b; do
    (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FORCE=true \
      GITHUB_OUTPUT="$tree/output-$list" GITHUB_STEP_SUMMARY="$tree/summary" \
      GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=zgeoff/cloud \
      bash "$script" "$tree/derivations-$list")
  done

  assert_not_equals "$(head -1 "$tree/output-a")" "$(head -1 "$tree/output-b")" 'key of the other derivations'
}

it_fails_with_the_gh_error_and_writes_no_answer_when_gh_fails() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-atc-daemon.drv\n' > "$tree/derivations"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed
  # command, such as an API error
  jq -cn '{argv: ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/artifacts", "-f", null,
    "-f", "per_page=100", "--jq",
    "[.artifacts[] | select(.expired == false and .workflow_run.head_repository_id == .workflow_run.repository_id)][0].workflow_run.id // empty"],
    stderr: "HTTP 503: Service Unavailable\n", exit: 1}' > "$tree/gh-responses"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=zgeoff/cloud \
    bash "$script" "$tree/derivations") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'HTTP 503: Service Unavailable'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/summary"
  assert_status 1 "$status"
}

it_fails_with_its_usage_when_the_derivations_file_is_empty() {
  local status=0
  create_case_tree
  setup_test "$tree"
  : > "$tree/derivations"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_OUTPUT="$tree/output" GITHUB_STEP_SUMMARY="$tree/summary" \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=zgeoff/cloud \
    bash "$script" "$tree/derivations") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: decide-nixos-checks-build.sh <derivations>, a file of one derivation path per line'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

# setup_test <tree>: the gh stand-in in <tree>/bin, the home and temp folders the script runs
# with, the empty files the workflow's runner provides, and <tree>/repo, a repository with one
# commit that holds a build script.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo/scripts"
  : > "$tree/calls"
  # boot data: the runner creates both files before a step runs
  : > "$tree/output"
  : > "$tree/summary"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
  git -C "$tree/repo" init -q -b main
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # the case's trap removes it
  git -C "$tree/repo" config maintenance.auto false
  # boot data: a build script, so the key reads a blob that a later commit can change
  echo 'echo build' > "$tree/repo/scripts/run-nixos-checks.sh"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'add the build script'
}

run_cases
