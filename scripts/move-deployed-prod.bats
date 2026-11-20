#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for move-deployed-prod.sh: it moves the repository's deployed/prod tag with one gh api
# PATCH that never forces, then prints the moved line and appends it to the step summary; a
# refused move fails with gh's status and writes no summary; a missing argument or GitHub
# variable fails before gh runs. gh is a stand-in (create-stub-gh.sh) that replays the answer each
# case records. Each case runs the script under `env -i` and compares its whole stdout, stderr, gh
# call log and summary.
#
# The recorded answers follow GitHub's "Update a reference" endpoint through gh api. They are not
# checked against GitHub or a real gh, since no test reaches GitHub. They were checked on
# 2026-10-14 against https://docs.github.com/en/rest/git/refs#update-a-reference (200 with the
# reference object, 422 "Validation failed, or the endpoint has been spammed") and
# https://cli.github.com/manual/gh_api (the response body goes to stdout; an HTTP error exits 1).
# The docs do not settle the 422 message for a move that is not a fast forward, nor gh's exact
# stderr line; the refused answer follows what GitHub's API answers in practice and needs a real
# sample.
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
  script="$BATS_TEST_DIRNAME/move-deployed-prod.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
}

@test "it moves the tag without force and writes the summary" {
  setup_test "$tree"
  echo '## earlier step' > "$tree/summary"
  # a move GitHub takes: the updated reference's JSON on stdout, exit 0
  cat > "$tree/gh-responses" << 'EOF'
{"argv": ["gh", "api", "--method", "PATCH", "repos/zgeoff/cloud/git/refs/tags/deployed/prod", "-f", "sha=3333333333333333333333333333333333333333", "-F", "force=false"], "stdout": "{\"ref\":\"refs/tags/deployed/prod\",\"url\":\"https://api.github.com/repos/zgeoff/cloud/git/refs/tags/deployed/prod\",\"object\":{\"sha\":\"3333333333333333333333333333333333333333\",\"type\":\"commit\",\"url\":\"https://api.github.com/repos/zgeoff/cloud/git/commits/3333333333333333333333333333333333333333\"}}\n"}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TOKEN=gh-token \
    GITHUB_REPOSITORY=zgeoff/cloud GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script" 3333333333333333333333333333333333333333

  assert_output 'deployed/prod moved to 3333333333333333333333333333333333333333.'
  refute_stderr

  run -0 diff - "$tree/calls" <<< '["gh","api","--method","PATCH","repos/zgeoff/cloud/git/refs/tags/deployed/prod","-f","sha=3333333333333333333333333333333333333333","-F","force=false"]'
  run -0 diff - "$tree/summary" << 'EOF'
## earlier step
deployed/prod moved to 3333333333333333333333333333333333333333.
EOF
}

@test "it fails with ghs status and writes no summary when github refuses the move" {
  setup_test "$tree"
  : > "$tree/summary"
  # a move that is not a fast forward: GitHub's 422 body on stdout, gh's line on stderr, exit 1
  cat > "$tree/gh-responses" << 'EOF'
{"argv": ["gh", "api", "--method", "PATCH", "repos/zgeoff/cloud/git/refs/tags/deployed/prod", "-f", "sha=3333333333333333333333333333333333333333", "-F", "force=false"], "stdout": "{\"message\":\"Update is not a fast forward\",\"documentation_url\":\"https://docs.github.com/rest/git/refs#update-a-reference\",\"status\":\"422\"}\n", "stderr": "gh: Update is not a fast forward (HTTP 422)\n", "exit": 1}
EOF

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TOKEN=gh-token \
    GITHUB_REPOSITORY=zgeoff/cloud GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script" 3333333333333333333333333333333333333333

  refute_output
  assert_stderr 'gh: Update is not a fast forward (HTTP 422)'

  run -0 diff - "$tree/calls" <<< '["gh","api","--method","PATCH","repos/zgeoff/cloud/git/refs/tags/deployed/prod","-f","sha=3333333333333333333333333333333333333333","-F","force=false"]'
  run -0 diff /dev/null "$tree/summary"
}

@test "it fails before gh runs without a repository" {
  setup_test "$tree"
  : > "$tree/summary"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TOKEN=gh-token \
    GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script" 3333333333333333333333333333333333333333

  refute_output
  assert_stderr "$script: line 17: GITHUB_REPOSITORY: parameter null or not set"

  run -0 diff /dev/null "$tree/calls"
}

@test "it fails before gh runs without a step summary" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TOKEN=gh-token \
    GITHUB_REPOSITORY=zgeoff/cloud \
    bash "$script" 3333333333333333333333333333333333333333

  refute_output
  assert_stderr "$script: line 17: GITHUB_STEP_SUMMARY: parameter null or not set"

  run -0 diff /dev/null "$tree/calls"
}

@test "it rejects a missing revision with its usage" {
  setup_test "$tree"
  : > "$tree/summary"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TOKEN=gh-token \
    GITHUB_REPOSITORY=zgeoff/cloud GITHUB_STEP_SUMMARY="$tree/summary" \
    bash "$script"

  refute_output
  assert_stderr 'usage: move-deployed-prod.sh <revision>'

  run -0 diff /dev/null "$tree/calls"
}
