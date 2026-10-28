#!/usr/bin/env bash
# Hermetic test for ops.sh: each verb runs the command it wraps, in its directory, with the
# caller's arguments and stdin, and passes the exit code through; `up` and `cancel-prod-lock`
# first refuse while a Deploy prod run has not completed; --dry-run runs nothing. It touches no
# host and no GitHub: ops.sh runs from a copy in the case tree, beside a stand-in for
# switch-geoffcloud.sh, and gh, bun, op and ssh are stand-ins from test-support/shell that log
# their calls to one log. ssh runs a `bash -c` command in the case's host directory. Each case
# runs ops.sh under `env -i` and compares its whole stdout, stderr and call log, with the case
# tree's path masked, and its exact exit code. The last two cases read the real package.json and
# docs/runbooks/ops.md, so each verb has its package script and its runbook entry.
#
#   bash scripts/test-ops.sh
#   CASE='up' bash scripts/test-ops.sh   # the cases whose title holds it
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the stand-ins get do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-bash-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-scripted-command.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/require-remote-tool-stubs.sh"

it_switch_host_runs_switch_geoffcloud_with_its_flag_and_passes_its_failure_through() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo 1 > "$tree/answers/switch-geoffcloud.sh/1.status"
  echo 'no green NixOS checks run covers the commit' > "$tree/answers/switch-geoffcloud.sh/1.err"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh switch-host --allow-k3s-restart) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'no green NixOS checks run covers the commit'
  diff - <(sed "s|$tree|<tree>|g" "$tree/calls") <<< '{"cwd":"<tree>/repo","argv":["switch-geoffcloud.sh","--allow-k3s-restart"]}'
  assert_status 1 "$status"
}

it_deploy_prod_dispatches_the_workflow_on_main_with_the_revision() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh workflow run prints the new run's URL on stdout; gh help workflow run
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","workflow","run","deploy-prod.yml","-R","zgeoff/cloud","--ref","main","-f","revision=4f0c2a9e81b3d65c7a0e9f42b18d3c5e6a7f9b01"], "stdout": "https://github.com/zgeoff/cloud/actions/runs/41\n"}
JSON

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh deploy-prod 4f0c2a9e81b3d65c7a0e9f42b18d3c5e6a7f9b01) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/actions/runs/41'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","workflow","run","deploy-prod.yml","-R","zgeoff/cloud","--ref","main","-f","revision=4f0c2a9e81b3d65c7a0e9f42b18d3c5e6a7f9b01"]'
  assert_status 0 "$status"
}

it_deploy_prod_exits_2_without_a_call_for_a_short_commit() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh deploy-prod 4f0c2a9) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "usage: ops.sh deploy-prod <the full 40-character commit of main's tip>"
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

it_nixos_checks_dispatches_on_main_by_default() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh workflow run prints the new run's URL on stdout; gh help workflow run
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","workflow","run","nixos-checks.yml","-R","zgeoff/cloud","--ref","main"], "stdout": "https://github.com/zgeoff/cloud/actions/runs/44\n"}
JSON

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh nixos-checks) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/actions/runs/44'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","workflow","run","nixos-checks.yml","-R","zgeoff/cloud","--ref","main"]'
  assert_status 0 "$status"
}

it_nixos_checks_dispatches_a_pull_request_s_run_on_its_head_branch() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh pr view --json headRefName prints the branch with --jq; gh workflow run prints the new
  # run's URL on stdout; gh help pr view, gh help workflow run
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","pr","view","412","-R","zgeoff/cloud","--json","headRefName","--jq",".headRefName"], "stdout": "rename-backup-unit\n"}
{"argv": ["gh","workflow","run","nixos-checks.yml","-R","zgeoff/cloud","--ref","rename-backup-unit","-f","pull-request=412"], "stdout": "https://github.com/zgeoff/cloud/actions/runs/45\n"}
JSON

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh nixos-checks --pr 412) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/actions/runs/45'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","view","412","-R","zgeoff/cloud","--json","headRefName","--jq",".headRefName"]
["gh","workflow","run","nixos-checks.yml","-R","zgeoff/cloud","--ref","rename-backup-unit","-f","pull-request=412"]
EOF
  assert_status 0 "$status"
}

it_nixos_checks_refuses_a_branch_without_its_pull_request_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh nixos-checks rename-backup-unit) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: ops.sh nixos-checks [--force] [--pr <pull request number>]'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

it_nixos_checks_dispatches_a_forced_build_with_force() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh workflow run passes a workflow input with -f; gh help workflow run
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","workflow","run","nixos-checks.yml","-R","zgeoff/cloud","--ref","main","-f","force=true"], "stdout": "https://github.com/zgeoff/cloud/actions/runs/46\n"}
JSON

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh nixos-checks --force) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/actions/runs/46'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","workflow","run","nixos-checks.yml","-R","zgeoff/cloud","--ref","main","-f","force=true"]'
  assert_status 0 "$status"
}

it_preview_runs_the_preview_script_from_the_repo_root_with_its_flags() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo 0 > "$tree/answers/bun/1.status"
  printf 'Resources:\n    42 unchanged\n' > "$tree/answers/bun/1.out"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh preview --refresh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
Resources:
    42 unchanged
OUT
  diff /dev/null "$tree/err"
  diff - <(sed "s|$tree|<tree>|g" "$tree/calls") <<< '{"cwd":"<tree>/repo","argv":["bun","run","preview","--","--refresh"]}'
  assert_status 0 "$status"
}

it_up_refuses_naming_each_deploy_prod_run_that_is_in_progress_or_waiting() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh run list --status --json prints an array of the named fields of the runs in that status,
  # an empty one when none is; gh help run list
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"], "stdout": "[{\"status\":\"in_progress\",\"url\":\"https://github.com/zgeoff/cloud/actions/runs/42\"}]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","queued","-L","100","--json","status,url"], "stdout": "[]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","waiting","-L","100","--json","status,url"], "stdout": "[{\"status\":\"waiting\",\"url\":\"https://github.com/zgeoff/cloud/actions/runs/46\"}]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","pending","-L","100","--json","status,url"], "stdout": "[]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","requested","-L","100","--json","status,url"], "stdout": "[]\n"}
JSON

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh up --yes) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
ops: a Deploy prod run has not completed; wait for it, then run the verb again:
  in_progress https://github.com/zgeoff/cloud/actions/runs/42
  waiting https://github.com/zgeoff/cloud/actions/runs/46
ERR
  diff - "$tree/calls" << 'CALLS'
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","queued","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","waiting","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","pending","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","requested","-L","100","--json","status,url"]
CALLS
  assert_status 1 "$status"
}

it_up_runs_the_up_script_from_the_repo_root_when_no_deploy_prod_run_is_unfinished() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh run list --status --json prints an empty array when no run is in that status; gh help run list
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"], "stdout": "[]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","queued","-L","100","--json","status,url"], "stdout": "[]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","waiting","-L","100","--json","status,url"], "stdout": "[]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","pending","-L","100","--json","status,url"], "stdout": "[]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","requested","-L","100","--json","status,url"], "stdout": "[]\n"}
JSON
  echo 0 > "$tree/answers/bun/1.status"
  echo 'Update succeeded' > "$tree/answers/bun/1.out"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh up --yes) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'Update succeeded'
  diff /dev/null "$tree/err"
  diff - <(sed "s|$tree|<tree>|g" "$tree/calls") << 'CALLS'
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","queued","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","waiting","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","pending","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","requested","-L","100","--json","status,url"]
{"cwd":"<tree>/repo","argv":["bun","run","up","--","--yes"]}
CALLS
  assert_status 0 "$status"
}

it_up_stops_with_gh_s_error_and_exit_when_gh_cannot_list_the_runs() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh exits 4 with this message when it holds no token; gh help exit-codes, gh help environment
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"], "stderr": "To get started with GitHub CLI, please run:  gh auth login\n", "exit": 4}
JSON

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh up --yes) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'To get started with GitHub CLI, please run:  gh auth login'
  diff - "$tree/calls" <<< '["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"]'
  assert_status 4 "$status"
}

it_switch_agent_image_runs_the_switch_script_with_the_image() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo 0 > "$tree/answers/bun/1.status"
  echo 'the cloud target already runs agent-7c1e2d4' > "$tree/answers/bun/1.out"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh switch-agent-image agent-7c1e2d4) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'the cloud target already runs agent-7c1e2d4'
  diff /dev/null "$tree/err"
  diff - <(sed "s|$tree|<tree>|g" "$tree/calls") <<< '{"cwd":"<tree>/repo","argv":["bun","<tree>/repo/scripts/switch-agent-image.ts","agent-7c1e2d4"]}'
  assert_status 0 "$status"
}

it_host_runs_the_command_on_geoffcloud_with_the_caller_s_stdin() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    bash repo/scripts/ops.sh host 'bash -c "install -m 600 /dev/stdin drop && cat drop"') \
    <<< 'a value sent on stdin' > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'a value sent on stdin'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","bash -c \"install -m 600 /dev/stdin drop && cat drop\""]'
  assert_status 0 "$status"
}

it_host_runs_the_command_on_the_host_GEOFFCLOUD_HOST_names_and_passes_its_exit_through() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" STUB_HOST=root@cloud-staging STUB_HOST_BIN="$tree/host-bin" GEOFFCLOUD_HOST=root@cloud-staging \
    bash repo/scripts/ops.sh host 'bash -c "echo inactive; exit 3"') > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'inactive'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@cloud-staging","bash -c \"echo inactive; exit 3\""]'
  assert_status 3 "$status"
}

it_host_exits_2_without_a_call_when_the_command_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh host) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "usage: ops.sh host '<remote command>'"
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

it_cancel_prod_lock_runs_pulumi_cancel_on_prod_from_infra_when_no_deploy_prod_run_is_unfinished() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh run list --status --json prints an empty array when no run is in that status; gh help run list
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"], "stdout": "[]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","queued","-L","100","--json","status,url"], "stdout": "[]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","waiting","-L","100","--json","status,url"], "stdout": "[]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","pending","-L","100","--json","status,url"], "stdout": "[]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","requested","-L","100","--json","status,url"], "stdout": "[]\n"}
JSON
  echo 0 > "$tree/answers/op/1.status"
  echo "The currently running update for 'prod' has been canceled!" > "$tree/answers/op/1.out"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh cancel-prod-lock --yes) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "The currently running update for 'prod' has been canceled!"
  diff /dev/null "$tree/err"
  diff - <(sed "s|$tree|<tree>|g" "$tree/calls") << 'CALLS'
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","queued","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","waiting","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","pending","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","requested","-L","100","--json","status,url"]
{"cwd":"<tree>/repo/infra","argv":["op","run","--env-file=../.env","--","pulumi","cancel","--stack","prod","--yes"]}
CALLS
  assert_status 0 "$status"
}

it_cancel_prod_lock_refuses_while_a_deploy_prod_run_is_queued() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh run list --status --json prints an array of the named fields of the runs in that status,
  # an empty one when none is; gh help run list
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"], "stdout": "[]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","queued","-L","100","--json","status,url"], "stdout": "[{\"status\":\"queued\",\"url\":\"https://github.com/zgeoff/cloud/actions/runs/43\"}]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","waiting","-L","100","--json","status,url"], "stdout": "[]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","pending","-L","100","--json","status,url"], "stdout": "[]\n"}
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","requested","-L","100","--json","status,url"], "stdout": "[]\n"}
JSON

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh cancel-prod-lock --yes) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
ops: a Deploy prod run has not completed; wait for it, then run the verb again:
  queued https://github.com/zgeoff/cloud/actions/runs/43
ERR
  diff - "$tree/calls" << 'CALLS'
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","queued","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","waiting","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","pending","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","requested","-L","100","--json","status,url"]
CALLS
  assert_status 1 "$status"
}

it_dry_run_prints_the_check_and_the_command_and_runs_neither() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh cancel-prod-lock --dry-run --yes) > "$tree/out" 2> "$tree/err" || status=$?

  diff - <(sed "s|$tree|<tree>|g" "$tree/out") << 'OUT'
check: no Deploy prod run of zgeoff/cloud is queued or in progress
run in <tree>/repo/infra: op run --env-file=../.env -- pulumi cancel --stack prod --yes
OUT
  diff /dev/null "$tree/err"
  diff /dev/null "$tree/calls"
  assert_status 0 "$status"
}

it_exits_2_with_the_verbs_for_an_unknown_verb() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh destroy) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: ops.sh <verb> [--dry-run] [<argument>…], where <verb> is one of: switch-host deploy-prod nixos-checks preview up switch-agent-image host cancel-prod-lock'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

it_has_a_package_script_for_each_verb_and_none_other() {
  local repo
  create_case_tree
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  bash "$repo/scripts/ops.sh" 2> "$tree/usage" || true
  sed 's/.*one of: //' "$tree/usage" | tr ' ' '\n' | sed 's|.*|ops:& bash scripts/ops.sh &|' > "$tree/expected"
  jq -r '.scripts | to_entries[] | select(.key | startswith("ops:")) | "\(.key) \(.value)"' "$repo/package.json" > "$tree/scripts"

  diff "$tree/expected" "$tree/scripts"
}

it_has_a_runbook_entry_for_each_verb_in_the_verbs_order() {
  local repo
  create_case_tree
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  bash "$repo/scripts/ops.sh" 2> "$tree/usage" || true
  sed 's/.*one of: //' "$tree/usage" | tr ' ' '\n' > "$tree/expected"
  # shellcheck disable=SC2016 # the backticks are the Markdown heading's code span
  sed -n 's/^## `bun run ops:\([a-z-]*\)`$/\1/p' "$repo/docs/runbooks/ops.md" > "$tree/entries"

  diff "$tree/expected" "$tree/entries"
}

# setup_test <tree>: a copy of ops.sh in <tree>/repo with a switch-geoffcloud.sh stand-in beside
# it, and gh, bun, op and ssh stand-ins that log to <tree>/calls, each scripted one answering from
# <tree>/answers/<name>; every other remote tool fails closed, on the PATH and on the host's
setup_test() {
  local tree="$1" repo name
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  mkdir -p "$tree/bin" "$tree/host-bin" "$tree/home" "$tree/tmp" "$tree/repo/scripts" "$tree/repo/infra"
  : > "$tree/calls"
  cp "$repo/scripts/ops.sh" "$tree/repo/scripts/ops.sh"
  for name in switch-geoffcloud.sh bun op; do mkdir -p "$tree/answers/$name"; done
  create_stub_scripted_command "$tree/repo/scripts" switch-geoffcloud.sh "$tree/calls" "$tree/answers/switch-geoffcloud.sh"
  create_stub_scripted_command "$tree/bin" bun "$tree/calls" "$tree/answers/bun"
  create_stub_scripted_command "$tree/bin" op "$tree/calls" "$tree/answers/op"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
  create_stub_bash_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  create_stub_remote_tools "$tree/host-bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
