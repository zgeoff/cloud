#!/usr/bin/env bash
# Test for check-out-deployed-revision.sh: against a real git repository in the case tree and a
# bun stand-in (test-support/shell/create-stub-prod-apply-bun.sh), it checks out the deployed
# commit as a detached worktree in the runner's temp directory, points that checkout's .env at
# the deploy vault, and installs its dependencies there; it stops with git's error on a commit
# git cannot resolve, before the install on an env reference outside the cloud vault, with the
# install's status on a failed install, and on a missing variable. Each case runs the script
# under `env -i` with git's global and system config off, and compares its whole stdout, stderr,
# the checkout's files and the bun call log.
#
#   bash scripts/test-check-out-deployed-revision.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-prod-apply-bun.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-out-deployed-revision.sh"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository, user or
# system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_checks_out_the_deployed_commit_points_its_env_at_the_deploy_vault_and_installs_there() {
  local deployed short status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '# the stack secrets\nONIDEL_API_KEY=op://cloud/onidel/credential\nREGION=syd\n' > "$tree/repo/.env"
  echo deployed > "$tree/repo/marker"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'the deployed revision'
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  short="$(git -C "$tree/repo" rev-parse --short HEAD)"
  echo newer > "$tree/repo/marker"
  git -C "$tree/repo" commit -qam 'a newer revision'

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    RUNNER_TEMP="$tree/runner" DEPLOYED="$deployed" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "HEAD is now at $short the deployed revision"
  diff - "$tree/err" <<< "Preparing worktree (detached HEAD $short)"
  diff - "$tree/runner/deployed/marker" <<< deployed
  diff - "$tree/runner/deployed/.env" << 'EOF'
# the stack secrets
ONIDEL_API_KEY=op://cloud-deploy/onidel/credential
REGION=syd
EOF
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/runner/deployed\",\"argv\":[\"bun\",\"install\",\"--frozen-lockfile\"]}"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_with_git_s_error_on_a_deployed_commit_git_cannot_resolve() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf 'ONIDEL_API_KEY=op://cloud/onidel/credential\n' > "$tree/repo/.env"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'the deployed revision'

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    RUNNER_TEMP="$tree/runner" DEPLOYED=0000000000000000000000000000000000000001 \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'fatal: invalid reference: 0000000000000000000000000000000000000001'
  [ ! -e "$tree/runner/deployed" ] || {
    echo "the script left $tree/runner/deployed" >&2
    exit 1
  }
  diff /dev/null "$tree/calls"
  [ "$status" = 128 ] || {
    echo "exit $status, want 128" >&2
    exit 1
  }
}

it_stops_before_the_install_when_the_deployed_env_names_another_vault() {
  local deployed short status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf 'ONIDEL_API_KEY=op://personal/onidel/credential\n' > "$tree/repo/.env"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'the deployed revision'
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  short="$(git -C "$tree/repo" rev-parse --short HEAD)"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    RUNNER_TEMP="$tree/runner" DEPLOYED="$deployed" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "HEAD is now at $short the deployed revision"
  diff - "$tree/err" << EOF
Preparing worktree (detached HEAD $short)
write-deploy-env: a reference outside the cloud vault: ONIDEL_API_KEY
EOF
  diff - "$tree/runner/deployed/.env" <<< 'ONIDEL_API_KEY=op://personal/onidel/credential'
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_with_the_install_s_exit_when_the_install_fails() {
  local deployed short status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf 'ONIDEL_API_KEY=op://cloud/onidel/credential\n' > "$tree/repo/.env"
  git -C "$tree/repo" add -A
  git -C "$tree/repo" commit -qm 'the deployed revision'
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"
  short="$(git -C "$tree/repo" rev-parse --short HEAD)"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" STUB_INSTALL_EXIT=1 \
    RUNNER_TEMP="$tree/runner" DEPLOYED="$deployed" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "HEAD is now at $short the deployed revision"
  diff - "$tree/err" <<< "Preparing worktree (detached HEAD $short)"
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/runner/deployed\",\"argv\":[\"bun\",\"install\",\"--frozen-lockfile\"]}"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_to_run_without_the_runner_s_temp_directory() {
  local deployed status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  deployed="$(git -C "$tree/repo" rev-parse HEAD)"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    DEPLOYED="$deployed" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'check-out-deployed-revision: set RUNNER_TEMP'
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo" "$tree/runner"
  : > "$tree/calls"
  create_stub_prod_apply_bun "$tree/bin"
  git -C "$tree/repo" init -q -b main
  # boot data: an empty root commit, so HEAD resolves
  git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
