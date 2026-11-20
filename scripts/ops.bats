#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Hermetic test for ops.sh: each verb runs the command it wraps, in its directory, with the
# caller's arguments and stdin, and passes the exit code through; `up` and `cancel-prod-lock`
# first refuse while a Deploy prod run has not completed; --dry-run runs nothing. It touches no
# host and no GitHub: ops.sh runs from a copy in the case tree, beside a stand-in for
# switch-geoffcloud.sh, and gh, bun, op and ssh are stand-ins from scripts/src/test-utils/shell that log
# their calls to one log. ssh runs a `bash -c` command in the case's host directory. Each case
# runs ops.sh under `env -i` and compares its whole stdout, stderr and call log, with the case
# tree's path masked, and its exact exit code. The last two cases read the real package.json and
# docs/runbooks/ops.md, so each verb has its package script and its runbook entry.
#
#   bash scripts/run-bats.sh
#   CASE='up' bash scripts/run-bats.sh   # the cases whose title holds it

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-gh.sh'
  load 'src/test-utils/shell/create-stub-bash-ssh.sh'
  load 'src/test-utils/shell/create-stub-scripted-command.sh'
  load 'src/test-utils/shell/create-stub-remote-tools.sh'
  load 'src/test-utils/shell/require-remote-tool-stubs.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# setup_test <tree>: a copy of ops.sh in <tree>/repo with a switch-geoffcloud.sh stand-in beside
# it, and gh, bun, op and ssh stand-ins that log to <tree>/calls, each scripted one answering from
# <tree>/answers/<name>; every other remote tool fails closed, on the PATH and on the host's
setup_test() {
  local tree="$1" repo name
  repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
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

@test "it switch host runs switch geoffcloud with its flag and passes its failure through" {
  setup_test "$tree"
  echo 1 > "$tree/answers/switch-geoffcloud.sh/1.status"
  echo 'no green NixOS checks run covers the commit' > "$tree/answers/switch-geoffcloud.sh/1.err"

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh switch-host --allow-k3s-restart

  refute_output
  assert_stderr 'no green NixOS checks run covers the commit'

  run -0 diff - <(sed "s|$tree|<tree>|g" "$tree/calls") <<< '{"cwd":"<tree>/repo","argv":["switch-geoffcloud.sh","--allow-k3s-restart"]}'
}

@test "it deploy prod dispatches the workflow on main with the revision" {
  setup_test "$tree"
  # gh workflow run prints the new run's URL on stdout; gh help workflow run
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","workflow","run","deploy-prod.yml","-R","zgeoff/cloud","--ref","main","-f","revision=4f0c2a9e81b3d65c7a0e9f42b18d3c5e6a7f9b01"], "stdout": "https://github.com/zgeoff/cloud/actions/runs/41\n"}
JSON

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh deploy-prod 4f0c2a9e81b3d65c7a0e9f42b18d3c5e6a7f9b01

  assert_output 'https://github.com/zgeoff/cloud/actions/runs/41'
  refute_stderr

  run -0 diff - "$tree/calls" <<< '["gh","workflow","run","deploy-prod.yml","-R","zgeoff/cloud","--ref","main","-f","revision=4f0c2a9e81b3d65c7a0e9f42b18d3c5e6a7f9b01"]'
}

@test "it deploy prod exits 2 without a call for a short commit" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh deploy-prod 4f0c2a9

  refute_output
  assert_stderr "usage: ops.sh deploy-prod <the full 40-character commit of main's tip>"

  run -0 diff /dev/null "$tree/calls"
}

@test "it nixos checks dispatches on main by default" {
  setup_test "$tree"
  # gh workflow run prints the new run's URL on stdout; gh help workflow run
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","workflow","run","nixos-checks.yml","-R","zgeoff/cloud","--ref","main"], "stdout": "https://github.com/zgeoff/cloud/actions/runs/44\n"}
JSON

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh nixos-checks

  assert_output 'https://github.com/zgeoff/cloud/actions/runs/44'
  refute_stderr

  run -0 diff - "$tree/calls" <<< '["gh","workflow","run","nixos-checks.yml","-R","zgeoff/cloud","--ref","main"]'
}

@test "it nixos checks dispatches on the branch it is given" {
  setup_test "$tree"
  # gh workflow run prints the new run's URL on stdout; gh help workflow run
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","workflow","run","nixos-checks.yml","-R","zgeoff/cloud","--ref","rename-backup-unit"], "stdout": "https://github.com/zgeoff/cloud/actions/runs/45\n"}
JSON

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh nixos-checks rename-backup-unit

  assert_output 'https://github.com/zgeoff/cloud/actions/runs/45'
  refute_stderr

  run -0 diff - "$tree/calls" <<< '["gh","workflow","run","nixos-checks.yml","-R","zgeoff/cloud","--ref","rename-backup-unit"]'
}

@test "it nixos checks dispatches a forced build with force" {
  setup_test "$tree"
  # gh workflow run passes a workflow input with -f; gh help workflow run
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","workflow","run","nixos-checks.yml","-R","zgeoff/cloud","--ref","main","-f","force=true"], "stdout": "https://github.com/zgeoff/cloud/actions/runs/46\n"}
JSON

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh nixos-checks --force

  assert_output 'https://github.com/zgeoff/cloud/actions/runs/46'
  refute_stderr

  run -0 diff - "$tree/calls" <<< '["gh","workflow","run","nixos-checks.yml","-R","zgeoff/cloud","--ref","main","-f","force=true"]'
}

@test "it preview runs the preview script from the repo root with its flags" {
  setup_test "$tree"
  echo 0 > "$tree/answers/bun/1.status"
  printf 'Resources:\n    42 unchanged\n' > "$tree/answers/bun/1.out"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh preview --refresh

  assert_output - << 'OUT'
Resources:
    42 unchanged
OUT
  refute_stderr

  run -0 diff - <(sed "s|$tree|<tree>|g" "$tree/calls") <<< '{"cwd":"<tree>/repo","argv":["bun","run","preview","--","--refresh"]}'
}

@test "it up refuses naming each deploy prod run that is in progress or waiting" {
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

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh up --yes

  refute_output
  assert_stderr - << 'ERR'
ops: a Deploy prod run has not completed; wait for it, then run the verb again:
  in_progress https://github.com/zgeoff/cloud/actions/runs/42
  waiting https://github.com/zgeoff/cloud/actions/runs/46
ERR

  run -0 diff - "$tree/calls" << 'CALLS'
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","queued","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","waiting","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","pending","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","requested","-L","100","--json","status,url"]
CALLS
}

@test "it up runs the up script from the repo root when no deploy prod run is unfinished" {
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

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh up --yes

  assert_output 'Update succeeded'
  refute_stderr

  run -0 diff - <(sed "s|$tree|<tree>|g" "$tree/calls") << 'CALLS'
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","queued","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","waiting","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","pending","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","requested","-L","100","--json","status,url"]
{"cwd":"<tree>/repo","argv":["bun","run","up","--","--yes"]}
CALLS
}

@test "it up stops with gh s error and exit when gh cannot list the runs" {
  setup_test "$tree"
  # gh exits 4 with this message when it holds no token; gh help exit-codes, gh help environment
  cat > "$tree/gh-responses" << 'JSON'
{"argv": ["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"], "stderr": "To get started with GitHub CLI, please run:  gh auth login\n", "exit": 4}
JSON

  run -4 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh up --yes

  refute_output
  assert_stderr 'To get started with GitHub CLI, please run:  gh auth login'

  run -0 diff - "$tree/calls" <<< '["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"]'
}

@test "it switch agent image runs the switch script with the image" {
  setup_test "$tree"
  echo 0 > "$tree/answers/bun/1.status"
  echo 'the cloud target already runs agent-7c1e2d4' > "$tree/answers/bun/1.out"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh switch-agent-image agent-7c1e2d4

  assert_output 'the cloud target already runs agent-7c1e2d4'
  refute_stderr

  run -0 diff - <(sed "s|$tree|<tree>|g" "$tree/calls") <<< '{"cwd":"<tree>/repo","argv":["bun","<tree>/repo/scripts/switch-agent-image.ts","agent-7c1e2d4"]}'
}

@test "it host runs the command on geoffcloud with the caller s stdin" {
  setup_test "$tree"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    bash repo/scripts/ops.sh host 'bash -c "install -m 600 /dev/stdin drop && cat drop"' \
    <<< 'a value sent on stdin'

  assert_output 'a value sent on stdin'
  refute_stderr

  run -0 diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","bash -c \"install -m 600 /dev/stdin drop && cat drop\""]'
}

@test "it host runs the command on the host GEOFFCLOUD HOST names and passes its exit through" {
  setup_test "$tree"

  run -3 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" STUB_HOST=root@cloud-staging STUB_HOST_BIN="$tree/host-bin" GEOFFCLOUD_HOST=root@cloud-staging \
    bash repo/scripts/ops.sh host 'bash -c "echo inactive; exit 3"'

  assert_output 'inactive'
  refute_stderr

  run -0 diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@cloud-staging","bash -c \"echo inactive; exit 3\""]'
}

@test "it host exits 2 without a call when the command is missing" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh host

  refute_output
  assert_stderr "usage: ops.sh host '<remote command>'"

  run -0 diff /dev/null "$tree/calls"
}

@test "it cancel prod lock runs pulumi cancel on prod from infra when no deploy prod run is unfinished" {
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

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh cancel-prod-lock --yes

  assert_output "The currently running update for 'prod' has been canceled!"
  refute_stderr

  run -0 diff - <(sed "s|$tree|<tree>|g" "$tree/calls") << 'CALLS'
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","queued","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","waiting","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","pending","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","requested","-L","100","--json","status,url"]
{"cwd":"<tree>/repo/infra","argv":["op","run","--env-file=../.env","--","pulumi","cancel","--stack","prod","--yes"]}
CALLS
}

@test "it cancel prod lock refuses while a deploy prod run is queued" {
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

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh cancel-prod-lock --yes

  refute_output
  assert_stderr - << 'ERR'
ops: a Deploy prod run has not completed; wait for it, then run the verb again:
  queued https://github.com/zgeoff/cloud/actions/runs/43
ERR

  run -0 diff - "$tree/calls" << 'CALLS'
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","in_progress","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","queued","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","waiting","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","pending","-L","100","--json","status,url"]
["gh","run","list","-R","zgeoff/cloud","--workflow","deploy-prod.yml","--status","requested","-L","100","--json","status,url"]
CALLS
}

@test "it dry run prints the check and the command and runs neither" {
  setup_test "$tree"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh cancel-prod-lock --dry-run --yes

  refute_stderr
  # shellcheck disable=SC2001 # a regex mask, which ${variable//search/replace} cannot express
  output="$(sed "s|$tree|<tree>|g" <<< "$output")"
  assert_output - << 'OUT'
check: no Deploy prod run of zgeoff/cloud is queued or in progress
run in <tree>/repo/infra: op run --env-file=../.env -- pulumi cancel --stack prod --yes
OUT
  run -0 diff /dev/null "$tree/calls"
}

@test "it exits 2 with the verbs for an unknown verb" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh destroy

  refute_output
  assert_stderr 'usage: ops.sh <verb> [--dry-run] [<argument>…], where <verb> is one of: switch-host deploy-prod nixos-checks preview up switch-agent-image host cancel-prod-lock store-nixie-verify-kubeconfig'

  run -0 diff /dev/null "$tree/calls"
}

@test "it store nixie verify kubeconfig runs the store script and passes its failure through" {
  setup_test "$tree"
  echo 1 > "$tree/answers/bun/1.status"
  echo 'write-nixie-verify-kubeconfig: kubectl minted no token for nixie-verify (exit 1)' > "$tree/answers/bun/1.err"

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh store-nixie-verify-kubeconfig

  refute_output
  assert_stderr 'write-nixie-verify-kubeconfig: kubectl minted no token for nixie-verify (exit 1)'

  run -0 diff - <(sed "s|$tree|<tree>|g" "$tree/calls") <<< '{"cwd":"<tree>/repo","argv":["bun","<tree>/repo/scripts/write-nixie-verify-kubeconfig.ts"]}'
}

@test "it store nixie verify kubeconfig exits 2 without a call for an argument" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash repo/scripts/ops.sh store-nixie-verify-kubeconfig 90d

  refute_output
  assert_stderr 'usage: ops.sh store-nixie-verify-kubeconfig'

  run -0 diff /dev/null "$tree/calls"
}

@test "it has a package script for each verb and none other" {
  local repo
  repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  bash "$repo/scripts/ops.sh" 2> "$tree/usage" || true
  sed 's/.*one of: //' "$tree/usage" | tr ' ' '\n' | sed 's|.*|ops:& bash scripts/ops.sh &|' > "$tree/expected"
  jq -r '.scripts | to_entries[] | select(.key | startswith("ops:")) | "\(.key) \(.value)"' "$repo/package.json" > "$tree/scripts"

  run -0 diff "$tree/expected" "$tree/scripts"
}

@test "it has a runbook entry for each verb in the verbs order" {
  local repo
  repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  bash "$repo/scripts/ops.sh" 2> "$tree/usage" || true
  sed 's/.*one of: //' "$tree/usage" | tr ' ' '\n' > "$tree/expected"
  # shellcheck disable=SC2016 # the backticks are the Markdown heading's code span
  sed -n 's/^## `bun run ops:\([a-z-]*\)`$/\1/p' "$repo/docs/runbooks/ops.md" > "$tree/entries"

  run -0 diff "$tree/expected" "$tree/entries"
}
