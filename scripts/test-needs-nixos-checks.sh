#!/usr/bin/env bash
# Test for needs-nixos-checks.sh: against a real git repository in the case tree, it prints true
# for a change to any input of the NixOS checks, false for a change to none of them, compares from
# the merge base, counts both paths of a rename, treats an all-zero base as needing the checks, and
# fails with git's error on a base git cannot resolve. Each case runs the script under `env -i`
# with git's global and system config off.
#
#   bash scripts/test-needs-nixos-checks.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/needs-nixos-checks.sh"

it_prints_true_for_a_change_under_nixos() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo changed >> "$tree/repo/nixos/flake.nix"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the flake'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_true_for_a_change_under_scripts() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo changed >> "$tree/repo/scripts/test-nixos.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change a script'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_true_for_a_change_to_the_root_package_json() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"name":"changed"}' > "$tree/repo/package.json"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change package.json'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_true_for_a_change_to_the_bun_version() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 9.9.9 > "$tree/repo/.bun-version"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the bun version'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_true_for_a_change_to_the_gitignore() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '*.log' >> "$tree/repo/.gitignore"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the gitignore'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_true_for_a_change_to_the_nixos_checks_workflow() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '# changed' >> "$tree/repo/.github/workflows/nixos-checks.yml"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the workflow'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_false_for_a_change_to_no_input_of_the_checks() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo changed >> "$tree/repo/infra/index.ts"
  echo changed >> "$tree/repo/docs/notes.md"
  echo '# changed' >> "$tree/repo/.github/workflows/ci.yml"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change infra, docs and another workflow'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< false
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_true_when_a_rename_moves_a_file_out_of_nixos() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" mv nixos/flake.nix docs/flake.nix
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'move the flake out of nixos'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_true_when_a_file_under_nixos_is_deleted() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rm -q nixos/flake.nix
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'remove the flake'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_false_when_only_the_base_branch_changed_nixos_after_the_fork() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -qc feature
  echo changed >> "$tree/repo/infra/index.ts"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change infra on the feature branch'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -q main
  echo changed >> "$tree/repo/nixos/flake.nix"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the flake on main'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" main feature) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< false
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_true_for_an_all_zero_base_without_reading_git() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/not-a-repo"

  (cd "$tree/not-a-repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" 0000000000000000000000000000000000000000 HEAD) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_with_gits_error_for_a_base_git_cannot_resolve() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" no-such-ref HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
fatal: ambiguous argument 'no-such-ref...HEAD': unknown revision or path not in the working tree.
Use '--' to separate paths from revisions, like this:
'git <command> [<revision>...] -- [<file>...]'
ERR
  [ "$status" = 128 ] || { echo "exit $status, want 128" >&2; exit 1; }
}

it_rejects_a_call_without_two_arguments_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: needs-nixos-checks.sh <base> <head>'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

# Runtime every case needs: a git repository on main whose first commit holds one file for each
# input of the checks and for some files outside them, with that commit's id in <tree>/base. The
# repository's own config holds the identity the cases commit with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/repo/nixos" "$tree/repo/scripts" "$tree/repo/infra" \
    "$tree/repo/docs" "$tree/repo/.github/workflows"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  echo '#!/usr/bin/env bash' > "$tree/repo/scripts/test-nixos.sh"
  echo 'export {};' > "$tree/repo/infra/index.ts"
  echo '# notes' > "$tree/repo/docs/notes.md"
  echo '{"name":"fixture"}' > "$tree/repo/package.json"
  echo 1.0.0 > "$tree/repo/.bun-version"
  echo node_modules > "$tree/repo/.gitignore"
  echo 'name: NixOS checks' > "$tree/repo/.github/workflows/nixos-checks.yml"
  echo 'name: CI' > "$tree/repo/.github/workflows/ci.yml"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" init -q -b main
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" config user.name fixture
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" config user.email fixture@example.invalid
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the fixture files'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
}

run_cases
