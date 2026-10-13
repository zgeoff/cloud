#!/usr/bin/env bash
# Test for merge-release-bump.sh: it squash-merges a release check pull request at the head it
# checked, with the merge token, once the app opened it from this repository, it is labelled
# auto-merge, it changes only its dependency's pin files, and every Actions check on its head
# passed, `ci` among them and `nixos` too when it changes nixos/. Any other pull request stays
# open, with the reason on stdout and exit 0. gh is the create-stub-release-gh.sh stand-in.
#
#   bash scripts/test-merge-release-bump.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/test-lib/run-cases.sh"
source "$scripts/test-lib/create-stub-release-gh.sh"

script="$scripts/merge-release-bump.sh"

# setup_test <tree>: the gh stand-in in <tree>/bin, and the home and temp folders the script runs
# with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_release_gh "$tree/bin"
}

it_merges_a_green_auto_merge_pull_request_with_the_merge_token() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":7}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"1111111111111111111111111111111111111111","labels":[{"name":"update:minor"},{"name":"auto-merge"}],"files":[{"path":"deploy/atc-gateway/versions.env"},{"path":"images/agent/Dockerfile"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"fixture","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"atc-gateway images"},{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"agent image"},{"__typename":"CheckRun","name":"auto-merge","status":"COMPLETED","conclusion":"SKIPPED","workflowName":"agent image"},{"__typename":"StatusContext","context":"CodeRabbit","state":"SUCCESS"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'merged #7 at 1111111111111111111111111111111111111111'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","7","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
["gh","pr","merge","7","--repo","zgeoff/cloud","--squash","--match-head-commit","1111111111111111111111111111111111111111"]
EOF
  diff - "$tree/tokens" << 'EOF'
read-token
read-token
merge-token
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_merges_a_green_auto_mode_bump_that_changes_only_the_agent_image() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":8}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"2222222222222222222222222222222222222222","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"2222222222222222222222222222222222222222","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"images/agent/Dockerfile"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"agent image"},{"__typename":"CheckRun","name":"auto-merge","status":"COMPLETED","conclusion":"SKIPPED","workflowName":"agent image"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/auto-mode > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'merged #8 at 2222222222222222222222222222222222222222'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/auto-mode","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","8","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
["gh","pr","merge","8","--repo","zgeoff/cloud","--squash","--match-head-commit","2222222222222222222222222222222222222222"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_holds_an_auto_mode_bump_that_changes_a_file_outside_the_agent_image() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":8}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"2222222222222222222222222222222222222222","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"2222222222222222222222222222222222222222","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"images/agent/Dockerfile"},{"path":"nixos/packages/atc.nix"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/auto-mode > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#8 stays open: it changes nixos/packages/atc.nix, which no pin of its dependency writes'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/auto-mode","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","8","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_holds_a_pull_request_while_a_check_is_pending() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":7}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"1111111111111111111111111111111111111111","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"images/agent/Dockerfile"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},{"__typename":"CheckRun","name":"check","status":"IN_PROGRESS","conclusion":null,"workflowName":"agent image"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#7 stays open: waiting for check'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","7","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_holds_a_pull_request_whose_check_failed_and_names_it() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":7}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"1111111111111111111111111111111111111111","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"images/agent/Dockerfile"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"FAILURE","workflowName":"agent image"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#7 stays open: check (FAILURE) did not pass'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","7","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_holds_a_pull_request_labelled_needs_review() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":7}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"1111111111111111111111111111111111111111","labels":[{"name":"update:major"},{"name":"needs-review"}],"files":[{"path":"images/agent/Dockerfile"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#7 stays open: it is not labelled auto-merge without needs-review'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","7","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_holds_a_pull_request_that_another_author_opened() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":7}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":false,"login":"someone"},"isCrossRepository":false,"headRefOid":"1111111111111111111111111111111111111111","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"images/agent/Dockerfile"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#7 stays open: app/cloud-release-check did not open it from zgeoff/cloud'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","7","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_holds_a_pull_request_from_another_repository() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":7}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":true,"headRefOid":"1111111111111111111111111111111111111111","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"images/agent/Dockerfile"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#7 stays open: app/cloud-release-check did not open it from zgeoff/cloud'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","7","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_holds_a_pull_request_that_changes_a_file_outside_its_pins() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":7}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"1111111111111111111111111111111111111111","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"infra/Pulumi.prod.yaml"},{"path":"scripts/pin-nixie.sh"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/nixie > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#7 stays open: it changes scripts/pin-nixie.sh, which no pin of its dependency writes'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/nixie","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","7","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_waits_for_the_nixos_checks_when_the_pull_request_changes_nixos() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":9}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"2222222222222222222222222222222222222222","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"nixos/flake.lock"},{"path":"nixos/flake.nix"},{"path":"nixos/hosts/geoffcloud/configuration.nix"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/imp > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#9 stays open: waiting for nixos (NixOS checks)'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/imp","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","9","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_merges_an_imp_pull_request_once_the_nixos_checks_passed() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":9}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"2222222222222222222222222222222222222222","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"images/agent/Dockerfile"},{"path":"nixos/flake.lock"},{"path":"nixos/flake.nix"},{"path":"nixos/hosts/geoffcloud/configuration.nix"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},{"__typename":"CheckRun","name":"nixos","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"NixOS checks"},{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"agent image"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/imp > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'merged #9 at 2222222222222222222222222222222222222222'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/imp","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","9","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
["gh","pr","merge","9","--repo","zgeoff/cloud","--squash","--match-head-commit","2222222222222222222222222222222222222222"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_merges_while_a_review_bot_status_is_pending() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":7}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"1111111111111111111111111111111111111111","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"infra/Pulumi.prod.yaml"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"fixture","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"nixie backup"},{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},{"__typename":"StatusContext","context":"CodeRabbit","state":"PENDING"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/nixie > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'merged #7 at 1111111111111111111111111111111111111111'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/nixie","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","7","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
["gh","pr","merge","7","--repo","zgeoff/cloud","--squash","--match-head-commit","1111111111111111111111111111111111111111"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_waits_for_ci_before_it_is_listed() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":7}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"1111111111111111111111111111111111111111","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"infra/Pulumi.prod.yaml"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"fixture","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"nixie backup"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/nixie > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#7 stays open: waiting for ci (CI)'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/nixie","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","7","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_skips_a_branch_that_is_not_a_release_check_branch() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/renovate > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'release-check/renovate is not a release check branch'
  diff /dev/null "$tree/err"
  [ ! -e "$tree/calls" ] || { echo "gh ran: $(cat "$tree/calls")" >&2; exit 1; }
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_skips_a_branch_without_an_open_pull_request() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'release-check/atc has no open pull request'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_without_the_app_login() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token MERGE_TOKEN=merge-token \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'APP_LOGIN must name the release check app, as app/<slug>'
  [ ! -e "$tree/calls" ] || { echo "gh ran: $(cat "$tree/calls")" >&2; exit 1; }
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_fails_without_the_merge_token() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "MERGE_TOKEN must hold the release check app's token"
  [ ! -e "$tree/calls" ] || { echo "gh ran: $(cat "$tree/calls")" >&2; exit 1; }
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_prints_its_usage_without_a_branch() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: merge-release-bump.sh <branch>'
  [ ! -e "$tree/calls" ] || { echo "gh ran: $(cat "$tree/calls")" >&2; exit 1; }
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_holds_a_pull_request_with_a_commit_that_another_author_pushed() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":7}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]},{"oid":"2222222222222222222222222222222222222222","authors":[{"login":"someone"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"2222222222222222222222222222222222222222","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"images/agent/Dockerfile"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#7 stays open: commits 2222222 are not all by cloud-release-check[bot]'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","7","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_reads_its_own_pull_request_past_a_forks_with_the_same_branch_name() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":true,"number":9},{"isCrossRepository":false,"number":7}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"1111111111111111111111111111111111111111","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"images/agent/Dockerfile"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"agent image"},{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'merged #7 at 1111111111111111111111111111111111111111'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","7","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
["gh","pr","merge","7","--repo","zgeoff/cloud","--squash","--match-head-commit","1111111111111111111111111111111111111111"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_waits_for_a_gateway_fixture_that_has_not_registered_its_check() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":7}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"1111111111111111111111111111111111111111","labels":[{"name":"update:minor"},{"name":"auto-merge"}],"files":[{"path":"deploy/atc-gateway/versions.env"},{"path":"images/agent/Dockerfile"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"agent image"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/atc > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#7 stays open: waiting for fixture (atc-gateway images)'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","7","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_waits_for_the_nixie_backup_fixture_past_another_workflows_fixture() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"isCrossRepository":false,"number":8}]' > "$tree/open-prs"
  cat > "$tree/pr-view" << 'EOF'
{"commits":[{"oid":"1111111111111111111111111111111111111111","authors":[{"login":"cloud-release-check[bot]"}]}],"author":{"is_bot":true,"login":"app/cloud-release-check"},"isCrossRepository":false,"headRefOid":"1111111111111111111111111111111111111111","labels":[{"name":"update:patch"},{"name":"auto-merge"}],"files":[{"path":"infra/Pulumi.prod.yaml"}],"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},{"__typename":"CheckRun","name":"fixture","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"atc-gateway images"}]}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    GH_TOKEN=read-token APP_LOGIN=app/cloud-release-check MERGE_TOKEN=merge-token \
    bash "$script" release-check/nixie > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#8 stays open: waiting for fixture (nixie backup)'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/nixie","--state","open","--json","number,isCrossRepository","--jq","[.[] | select(.isCrossRepository | not)][0].number // empty"]
["gh","pr","view","8","--repo","zgeoff/cloud","--json","author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

run_cases
