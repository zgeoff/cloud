#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for check-out-deployed-revision.sh: against a real git repository in the case tree and a
# bun stand-in (scripts/src/test-utils/shell/create-stub-prod-apply-bun.sh), it checks out the deployed
# commit as a detached worktree in the runner's temp directory, points that checkout's .env at
# the deploy vault, and installs its dependencies there; it stops with git's error on a commit
# git cannot resolve, before the install on an env reference outside the cloud vault, with the
# install's status on a failed install, and on a missing variable. Each case runs the script
# under `env -i` with git's global and system config off, and compares its whole stdout, stderr,
# the checkout's files and the bun call log.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-prod-apply-bun.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/check-out-deployed-revision.sh"
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
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo" "$tree/runner"
  : > "$tree/calls"
  create_stub_prod_apply_bun "$tree/bin"
  git -C "$tree/repo" init -q -b main
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # bats removes the case tree
  git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

@test "it checks out the deployed commit points its env at the deploy vault and installs there" {
  local deployed short
  setup_test "$tree"
  printf '# the stack secrets\nONIDEL_API_KEY=op://cloud/onidel/credential\nREGION=syd\n' > "$tree/repo/.env"
  echo deployed > "$tree/repo/marker"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'the deployed revision'
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  short="$(git -C "$tree/repo" rev-parse --short HEAD)"
  echo newer > "$tree/repo/marker"
  git -C "$tree/repo" commit -qam 'a newer revision'

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    RUNNER_TEMP="$tree/runner" DEPLOYED="$deployed" \
    bash "$script"

  assert_output "HEAD is now at $short the deployed revision"
  assert_stderr "Preparing worktree (detached HEAD $short)"

  run -0 diff - "$tree/runner/deployed/marker" <<< deployed
  run -0 diff - "$tree/runner/deployed/.env" << 'EOF'
# the stack secrets
ONIDEL_API_KEY=op://cloud-deploy/onidel/credential
REGION=syd
EOF
  run -0 diff - "$tree/calls" <<< "{\"cwd\":\"$tree/runner/deployed\",\"argv\":[\"bun\",\"install\",\"--frozen-lockfile\"]}"
}

@test "it fails with git s error on a deployed commit git cannot resolve" {
  setup_test "$tree"
  printf 'ONIDEL_API_KEY=op://cloud/onidel/credential\n' > "$tree/repo/.env"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'the deployed revision'

  run -128 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    RUNNER_TEMP="$tree/runner" DEPLOYED=0000000000000000000000000000000000000001 \
    bash "$script"

  refute_output
  assert_stderr 'fatal: invalid reference: 0000000000000000000000000000000000000001'

  refute [ -e "$tree/runner/deployed" ]
  run -0 diff /dev/null "$tree/calls"
}

@test "it stops before the install when the deployed env names another vault" {
  local deployed short
  setup_test "$tree"
  printf 'ONIDEL_API_KEY=op://personal/onidel/credential\n' > "$tree/repo/.env"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'the deployed revision'
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  short="$(git -C "$tree/repo" rev-parse --short HEAD)"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    RUNNER_TEMP="$tree/runner" DEPLOYED="$deployed" \
    bash "$script"

  assert_output "HEAD is now at $short the deployed revision"
  assert_stderr - << EOF
Preparing worktree (detached HEAD $short)
write-deploy-env: a reference outside the cloud vault: ONIDEL_API_KEY
EOF

  run -0 diff - "$tree/runner/deployed/.env" <<< 'ONIDEL_API_KEY=op://personal/onidel/credential'
  run -0 diff /dev/null "$tree/calls"
}

@test "it fails with the install s exit when the install fails" {
  local deployed short
  setup_test "$tree"
  printf 'ONIDEL_API_KEY=op://cloud/onidel/credential\n' > "$tree/repo/.env"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'the deployed revision'
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  short="$(git -C "$tree/repo" rev-parse --short HEAD)"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" STUB_INSTALL_EXIT=1 \
    RUNNER_TEMP="$tree/runner" DEPLOYED="$deployed" \
    bash "$script"

  assert_output "HEAD is now at $short the deployed revision"
  assert_stderr "Preparing worktree (detached HEAD $short)"

  run -0 diff - "$tree/calls" <<< "{\"cwd\":\"$tree/runner/deployed\",\"argv\":[\"bun\",\"install\",\"--frozen-lockfile\"]}"
}

@test "it refuses to run without the runner s temp directory" {
  local deployed
  setup_test "$tree"
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    DEPLOYED="$deployed" \
    bash "$script"

  refute_output
  assert_stderr 'check-out-deployed-revision: set RUNNER_TEMP'

  run -0 diff /dev/null "$tree/calls"
}
