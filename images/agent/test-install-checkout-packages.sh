#!/usr/bin/env bash
# Test for the agent image's SessionStart hook, sbin/install-checkout-packages: it runs a frozen
# `bun install` in a checkout that holds a bun.lock and no node_modules, keeps Bun's output off
# stdout, and says on stdout when the install fails. setup_test puts a scripted bun first on PATH,
# as the image's bun shim is, and each case runs the hook with `sh` under `env -i`, so CI runs it
# with dash, the guest's /bin/sh. check-agent-image.ts runs the hook with the real Bun in the image.
#
#   bash images/agent/test-install-checkout-packages.sh
# shellcheck source-path=SCRIPTDIR/../..
set -euo pipefail
umask 022
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-support/shell/run-cases.sh
source "$here/../../test-support/shell/run-cases.sh"
# shellcheck source=test-support/shell/create-case-tree.sh
source "$here/../../test-support/shell/create-case-tree.sh"
# shellcheck source=test-support/shell/assert-status.sh
source "$here/../../test-support/shell/assert-status.sh"
# shellcheck source=test-support/shell/assert-missing.sh
source "$here/../../test-support/shell/assert-missing.sh"
# shellcheck source=test-support/shell/create-stub-scripted-command.sh
source "$here/../../test-support/shell/create-stub-scripted-command.sh"

script="$here/sbin/install-checkout-packages"

# a scripted bun in $tree/bin, which logs to $tree/bun.log and answers from $tree/bun-answers, and
# an empty checkout folder at $tree/repo
setup_test() {
  create_case_tree
  mkdir -p "$tree/bin" "$tree/bun-answers" "$tree/repo"
  create_stub_scripted_command "$tree/bin" bun "$tree/bun.log" "$tree/bun-answers"
}

it_runs_a_frozen_install_in_a_locked_checkout_without_node_modules() {
  local status=0
  setup_test
  echo '{}' > "$tree/repo/bun.lock"
  echo '3 packages installed' > "$tree/bun-answers/1.out"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" TMPDIR="$tree" \
    CLAUDE_PROJECT_DIR="$tree/repo" sh "$script") < /dev/null > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '3 packages installed'
  diff - "$tree/bun.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"install\",\"--frozen-lockfile\"]}"
  assert_status 0 "$status"
}

it_keeps_the_node_modules_of_a_checkout_that_has_them() {
  local status=0
  setup_test
  echo '{}' > "$tree/repo/bun.lock"
  mkdir "$tree/repo/node_modules"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" TMPDIR="$tree" \
    CLAUDE_PROJECT_DIR="$tree/repo" sh "$script") < /dev/null > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  assert_missing "$tree/bun.log" 'bun log'
  assert_status 0 "$status"
}

it_installs_nothing_in_a_checkout_without_a_bun_lock() {
  local status=0
  setup_test
  echo '{}' > "$tree/repo/package.json"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" TMPDIR="$tree" \
    CLAUDE_PROJECT_DIR="$tree/repo" sh "$script") < /dev/null > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  assert_missing "$tree/bun.log" 'bun log'
  assert_status 0 "$status"
}

it_installs_nothing_without_a_project_folder() {
  local status=0
  setup_test
  echo '{}' > "$tree/repo/bun.lock"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" TMPDIR="$tree" \
    sh "$script") < /dev/null > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  assert_missing "$tree/bun.log" 'bun log'
  assert_status 0 "$status"
}

it_tells_the_session_to_install_when_the_frozen_install_fails() {
  local status=0
  setup_test
  echo '{}' > "$tree/repo/bun.lock"
  echo 'error: lockfile had changes, but lockfile is frozen' > "$tree/bun-answers/1.err"
  echo 1 > "$tree/bun-answers/1.status"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" TMPDIR="$tree" \
    CLAUDE_PROJECT_DIR="$tree/repo" sh "$script") < /dev/null > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "install-checkout-packages: \`bun install --frozen-lockfile\` failed in $tree/repo, so its hooks may import other package versions than its bun.lock pins; run the install before you rely on them."
  diff - "$tree/err" <<< 'error: lockfile had changes, but lockfile is frozen'
  diff - "$tree/bun.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"install\",\"--frozen-lockfile\"]}"
  assert_status 0 "$status"
}

run_cases
