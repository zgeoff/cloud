#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for the agent image's SessionStart hook, sbin/install-checkout-packages: it runs a frozen
# `bun install` in a checkout that holds a bun.lock and no node_modules, keeps Bun's output off
# stdout, and says on stdout when the install fails. setup_test puts a scripted bun first on PATH,
# as the image's bun shim is, and each case runs the hook with `sh` under `env -i`, so CI runs it
# with dash, the guest's /bin/sh. check-agent-image.ts runs the hook with the real Bun in the image.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../../scripts/src/test-utils/bats/setup'
}

setup() {
  load '../../scripts/src/test-utils/bats/setup'
  load '../../scripts/src/test-utils/shell/create-stub-scripted-command.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  script="$BATS_TEST_DIRNAME/sbin/install-checkout-packages"
}

teardown() {
  stop_timeout_watchdog
}

# a scripted bun in $tree/bin, which logs to $tree/bun.log and answers from $tree/bun-answers, and
# an empty checkout folder at $tree/repo
setup_test() {
  mkdir -p "$tree/bin" "$tree/bun-answers" "$tree/repo"
  create_stub_scripted_command "$tree/bin" bun "$tree/bun.log" "$tree/bun-answers"
}

@test "it runs a frozen install in a locked checkout without node modules" {
  setup_test
  echo '{}' > "$tree/repo/bun.lock"
  echo '3 packages installed' > "$tree/bun-answers/1.out"

  cd "$tree"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" TMPDIR="$tree" \
    CLAUDE_PROJECT_DIR="$tree/repo" sh "$script" < /dev/null > "$tree/out" 2> "$tree/err"

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '3 packages installed'
  diff - "$tree/bun.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"install\",\"--frozen-lockfile\"]}"
}

@test "it keeps the node modules of a checkout that has them" {
  setup_test
  echo '{}' > "$tree/repo/bun.lock"
  mkdir "$tree/repo/node_modules"

  cd "$tree"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" TMPDIR="$tree" \
    CLAUDE_PROJECT_DIR="$tree/repo" sh "$script" < /dev/null > "$tree/out" 2> "$tree/err"

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  refute [ -e "$tree/bun.log" ]
  refute [ -L "$tree/bun.log" ]
}

@test "it installs nothing in a checkout without a bun lock" {
  setup_test
  echo '{}' > "$tree/repo/package.json"

  cd "$tree"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" TMPDIR="$tree" \
    CLAUDE_PROJECT_DIR="$tree/repo" sh "$script" < /dev/null > "$tree/out" 2> "$tree/err"

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  refute [ -e "$tree/bun.log" ]
  refute [ -L "$tree/bun.log" ]
}

@test "it installs nothing without a project folder" {
  setup_test
  echo '{}' > "$tree/repo/bun.lock"

  cd "$tree/repo"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" TMPDIR="$tree" \
    sh "$script" < /dev/null > "$tree/out" 2> "$tree/err"

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  refute [ -e "$tree/bun.log" ]
  refute [ -L "$tree/bun.log" ]
}

@test "it tells the session to install when the frozen install fails" {
  setup_test
  echo '{}' > "$tree/repo/bun.lock"
  echo 'error: lockfile had changes, but lockfile is frozen' > "$tree/bun-answers/1.err"
  echo 1 > "$tree/bun-answers/1.status"

  cd "$tree"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" TMPDIR="$tree" \
    CLAUDE_PROJECT_DIR="$tree/repo" sh "$script" < /dev/null > "$tree/out" 2> "$tree/err"

  diff - "$tree/out" <<< "install-checkout-packages: \`bun install --frozen-lockfile\` failed in $tree/repo, so its hooks may import other package versions than its bun.lock pins; run the install before you rely on them."
  diff - "$tree/err" <<< 'error: lockfile had changes, but lockfile is frozen'
  diff - "$tree/bun.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"install\",\"--frozen-lockfile\"]}"
}
