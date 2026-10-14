#!/usr/bin/env bash
# Test for decide-release-bump-merge.sh: it reads the event file and runs the merge decision for
# the branch it names. A pull request whose auto-merge label came back after its checks finished
# is merged on the label event, and a finished check workflow decides on its head branch. A label
# other than auto-merge, a pull request or run from another repository, a check run on a push and
# any other event start no decision and call no gh. gh is the create-stub-release-gh.sh stand-in.
# Each case runs the script under `env -i` and compares its whole stdout, stderr, step summary and
# gh call log.
#
#   bash scripts/test-decide-release-bump-merge.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/../test-support/shell/run-cases.sh"
source "$scripts/../test-support/shell/create-stub-release-gh.sh"

script="$scripts/decide-release-bump-merge.sh"

# a green atc bump whose checks all finished, labelled auto-merge again
green_pr='{"commits":[{"oid":"3333333333333333333333333333333333333333","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"3333333333333333333333333333333333333333","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"deploy/atc-gateway/versions.env"},{"path":"images/agent/Dockerfile"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"agent image"},{"__typename":"CheckRun","name":"fixture","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"atc-gateway images"}]}'

it_merges_a_green_bump_when_its_auto_merge_label_comes_back_after_its_checks_finished() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":31}]' > "$tree/open-prs"
  echo "$green_pr" > "$tree/pr-view"
  cat > "$tree/event.json" << 'EOF'
{"action":"labeled","label":{"name":"auto-merge"},"pull_request":{"number":31,"head":{"ref":"release-check/atc","repo":{"full_name":"zgeoff/cloud"}}}}
EOF

  run_script "$tree" pull_request_target > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'merged #31 at 3333333333333333333333333333333333333333'
  diff /dev/null "$tree/err"
  diff - "$tree/summary" <<< 'merged #31 at 3333333333333333333333333333333333333333'
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","31","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
["gh","pr","merge","31","--repo","zgeoff/cloud","--squash","--match-head-commit","3333333333333333333333333333333333333333"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_decides_on_the_head_branch_of_a_finished_check_workflow() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/event.json" << 'EOF'
{"action":"completed","workflow_run":{"event":"pull_request","head_branch":"release-check/nixie","head_repository":{"full_name":"zgeoff/cloud"}}}
EOF

  run_script "$tree" workflow_run > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'release-check/nixie has no open pull request'
  diff /dev/null "$tree/err"
  diff - "$tree/summary" <<< 'release-check/nixie has no open pull request'
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/nixie","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_starts_no_decision_for_a_label_other_than_auto_merge() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/event.json" << 'EOF'
{"action":"labeled","label":{"name":"needs-review"},"pull_request":{"number":31,"head":{"ref":"release-check/atc","repo":{"full_name":"zgeoff/cloud"}}}}
EOF

  run_script "$tree" pull_request_target > "$tree/out" 2> "$tree/err" || status=$?

  assert_no_decision "$tree" pull_request_target
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_starts_no_decision_for_an_unlabeled_event() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/event.json" << 'EOF'
{"action":"unlabeled","label":{"name":"auto-merge"},"pull_request":{"number":31,"head":{"ref":"release-check/atc","repo":{"full_name":"zgeoff/cloud"}}}}
EOF

  run_script "$tree" pull_request_target > "$tree/out" 2> "$tree/err" || status=$?

  assert_no_decision "$tree" pull_request_target
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_starts_no_decision_for_a_label_on_a_pull_request_from_another_repository() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/event.json" << 'EOF'
{"action":"labeled","label":{"name":"auto-merge"},"pull_request":{"number":32,"head":{"ref":"release-check/atc","repo":{"full_name":"someone/cloud"}}}}
EOF

  run_script "$tree" pull_request_target > "$tree/out" 2> "$tree/err" || status=$?

  assert_no_decision "$tree" pull_request_target
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_starts_no_decision_for_a_check_workflow_from_another_repository() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/event.json" << 'EOF'
{"action":"completed","workflow_run":{"event":"pull_request","head_branch":"release-check/atc","head_repository":{"full_name":"someone/cloud"}}}
EOF

  run_script "$tree" workflow_run > "$tree/out" 2> "$tree/err" || status=$?

  assert_no_decision "$tree" workflow_run
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_starts_no_decision_for_a_check_workflow_on_a_push() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/event.json" << 'EOF'
{"action":"completed","workflow_run":{"event":"push","head_branch":"main","head_repository":{"full_name":"zgeoff/cloud"}}}
EOF

  run_script "$tree" workflow_run > "$tree/out" 2> "$tree/err" || status=$?

  assert_no_decision "$tree" workflow_run
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_starts_no_decision_for_another_event() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{}' > "$tree/event.json"

  run_script "$tree" workflow_dispatch > "$tree/out" 2> "$tree/err" || status=$?

  assert_no_decision "$tree" workflow_dispatch
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_without_the_event_file_before_calling_gh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    GITHUB_STEP_SUMMARY="$tree/summary" GITHUB_REPOSITORY=zgeoff/cloud \
    GITHUB_EVENT_NAME=pull_request_target bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$script: line 21: GITHUB_EVENT_PATH: parameter null or not set"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

# setup_test <tree>: the gh stand-in in <tree>/bin, the home and temp folders the script runs
# with, and the empty step summary the workflow's runner provides.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  # boot data: the runner creates the file before a step runs
  : > "$tree/summary"
  create_stub_release_gh "$tree/bin"
}

# run_script <tree> <event name>: runs the script as the workflow does, on <tree>/event.json
run_script() {
  local tree="$1"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    GITHUB_STEP_SUMMARY="$tree/summary" GITHUB_REPOSITORY=zgeoff/cloud \
    GITHUB_EVENT_NAME="$2" GITHUB_EVENT_PATH="$tree/event.json" bash "$script"
}

# assert_no_decision <tree> <event name>: the script said the event starts no decision, and
# called no gh and wrote no summary
assert_no_decision() {
  local tree="$1"
  diff - "$tree/out" <<< "this $2 event starts no merge decision"
  diff /dev/null "$tree/err"
  diff /dev/null "$tree/summary"
  diff /dev/null "$tree/calls"
}

run_cases
