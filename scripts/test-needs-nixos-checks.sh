#!/usr/bin/env bash
# Test for needs-nixos-checks.sh: against a real git repository in the case tree, it prints true
# for a change to each input of the NixOS checks, false for a change to none of them (the root
# package.json, .gitignore and the scripts the checks never read included), compares from
# the merge base, counts both paths of a rename, treats an all-zero base as needing the checks, and
# fails with git's error on a base git cannot resolve. Each case runs the script under `env -i`
# with git's global and system config off.
#
#   bash scripts/test-needs-nixos-checks.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/needs-nixos-checks.sh"

it_prints_true_for_a_change_under_nixos() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/nixos"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the flake'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/nixos/flake.nix"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the flake'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_run_nixos_checks_sh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/scripts"
  echo '#!/usr/bin/env bash' > "$tree/repo/scripts/run-nixos-checks.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a script'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/scripts/run-nixos-checks.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change a script'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_the_case_runner_the_checks_read() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/test-support/shell"
  echo '# shellcheck shell=bash' > "$tree/repo/test-support/shell/run-cases.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a test helper'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/test-support/shell/run-cases.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change a test helper'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_a_helper_suite_the_checks_run() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/test-support/shell"
  echo '#!/usr/bin/env bash' > "$tree/repo/test-support/shell/test-assert-missing.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a helper suite'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/test-support/shell/test-assert-missing.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change a helper suite'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_the_wait_helper_the_rehearsal_reads() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/test-support/shell"
  echo '# shellcheck shell=bash' > "$tree/repo/test-support/shell/wait-for.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the wait helper'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/test-support/shell/wait-for.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the wait helper'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_false_for_a_change_to_a_shell_stand_in_the_checks_never_read() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/test-support/shell"
  echo '# shellcheck shell=bash' > "$tree/repo/test-support/shell/create-stub-gh.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a stand-in'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/test-support/shell/create-stub-gh.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change a stand-in'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< false
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_false_for_a_change_to_the_impd_db_copy_script_on_this_machine() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/scripts"
  echo '#!/usr/bin/env bash' > "$tree/repo/scripts/copy-impd-db.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the copy script'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/scripts/copy-impd-db.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the copy script'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< false
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_the_nix_image_pin() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/scripts"
  echo '# the first pin' > "$tree/repo/scripts/nix-image.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'pin the nix image'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo '# the next pin' > "$tree/repo/scripts/nix-image.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'bump the nix image'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_needs_nixos_checks_sh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/scripts"
  echo '#!/usr/bin/env bash' > "$tree/repo/scripts/needs-nixos-checks.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the decision'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/scripts/needs-nixos-checks.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the decision'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_find_nixos_check_run_sh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/scripts"
  echo '#!/usr/bin/env bash' > "$tree/repo/scripts/find-nixos-check-run.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the run finder'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/scripts/find-nixos-check-run.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the run finder'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_decide_nixos_checks_sh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/scripts"
  echo '#!/usr/bin/env bash' > "$tree/repo/scripts/decide-nixos-checks.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the decision'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/scripts/decide-nixos-checks.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the decision'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_open_kvm_sh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/scripts"
  echo '#!/usr/bin/env bash' > "$tree/repo/scripts/open-kvm.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the kvm opener'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/scripts/open-kvm.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the kvm opener'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_move_host_secrets_sh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/scripts/host"
  echo '#!/usr/bin/env bash' > "$tree/repo/scripts/host/move-host-secrets.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the move script'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/scripts/host/move-host-secrets.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the move script'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_install_imp_dns_token_sh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/scripts"
  echo '#!/usr/bin/env bash' > "$tree/repo/scripts/install-imp-dns-token.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the dns token installer'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/scripts/install-imp-dns-token.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the dns token installer'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_write_atc_gateway_token_sh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/scripts/host"
  echo '#!/usr/bin/env bash' > "$tree/repo/scripts/host/write-atc-gateway-token.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the gateway token writer'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/scripts/host/write-atc-gateway-token.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the gateway token writer'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_the_shared_constants() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/packages/topology"
  echo '{}' > "$tree/repo/packages/topology/constants.json"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the constants'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo '{"atc":{}}' > "$tree/repo/packages/topology/constants.json"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the constants'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_the_preview_service_the_host_runs() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/packages/preview"
  echo 'export {};' > "$tree/repo/packages/preview/main.ts"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the preview service'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo '// changed' >> "$tree/repo/packages/preview/main.ts"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the preview service'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_false_for_a_change_to_another_package() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/packages/topology-docs"
  echo '# topology' > "$tree/repo/packages/topology-docs/README.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add another package'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/packages/topology-docs/README.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change another package'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< false
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_false_for_a_change_to_a_script_the_checks_never_read() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/scripts"
  echo '#!/usr/bin/env bash' > "$tree/repo/scripts/switch-geoffcloud.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the switch'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/scripts/switch-geoffcloud.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the switch'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< false
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_false_for_a_change_to_the_root_package_json() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"name":"fixture"}' > "$tree/repo/package.json"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add package.json'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo '{"name":"changed"}' > "$tree/repo/package.json"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change package.json'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< false
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_the_bun_version() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 1.0.0 > "$tree/repo/.bun-version"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the bun version'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo 9.9.9 > "$tree/repo/.bun-version"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the bun version'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_the_lockfile_the_preview_package_reads() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{ "lockfileVersion": 1 }' > "$tree/repo/bun.lock"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the lockfile'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo '{ "lockfileVersion": 2 }' > "$tree/repo/bun.lock"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the lockfile'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_false_for_a_change_to_the_gitignore() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo node_modules > "$tree/repo/.gitignore"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the gitignore'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo '*.log' >> "$tree/repo/.gitignore"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the gitignore'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< false
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_the_nixos_checks_workflow() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/.github/workflows"
  echo 'name: NixOS checks' > "$tree/repo/.github/workflows/nixos-checks.yml"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the workflow'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo '# changed' >> "$tree/repo/.github/workflows/nixos-checks.yml"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the workflow'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_false_for_a_change_to_no_input_of_the_checks() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/infra" "$tree/repo/docs" "$tree/repo/.github/workflows"
  echo 'export {};' > "$tree/repo/infra/index.ts"
  echo '# notes' > "$tree/repo/docs/notes.md"
  echo 'name: CI' > "$tree/repo/.github/workflows/ci.yml"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add infra, docs and another workflow'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/infra/index.ts"
  echo changed >> "$tree/repo/docs/notes.md"
  echo '# changed' >> "$tree/repo/.github/workflows/ci.yml"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change infra, docs and another workflow'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< false
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_when_a_rename_moves_a_file_out_of_nixos() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/nixos"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the flake'
  mkdir "$tree/repo/docs"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" mv nixos/flake.nix docs/flake.nix
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'move the flake out of nixos'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_when_a_file_under_nixos_is_deleted() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/nixos"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the flake'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rm -q nixos/flake.nix
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'remove the flake'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_false_for_a_merge_commit_whose_own_change_touches_no_input_after_main_changed_nixos() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/nixos" "$tree/repo/infra"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  echo 'export {};' > "$tree/repo/infra/index.ts"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the flake and infra'
  # as for a pull request: main changes the flake after the fork, and the head under test is the
  # merge of the feature branch into main
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -qc feature
  echo changed >> "$tree/repo/infra/index.ts"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change infra on the feature branch'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -q main
  echo changed >> "$tree/repo/nixos/flake.nix"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the flake on main'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" merge -q --no-edit feature

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" main~1 main) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< false
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_base_that_is_not_an_ancestor_of_the_head() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/nixos"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the flake'
  # as for a push that rewrote main: the old tip changed the flake, and the new tip is its parent
  echo changed >> "$tree/repo/nixos/flake.nix"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the flake'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/old-tip"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" reset -q --hard HEAD~1

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/old-tip")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_a_file_under_nixos_whose_name_git_quotes() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  mkdir "$tree/repo/nixos"
  echo '{ }' > "$tree/repo/nixos/é.nix"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a file whose name git quotes'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_rejects_an_empty_base_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" '' HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: needs-nixos-checks.sh <base> <head>'
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_fails_with_gits_error_for_a_commit_id_the_clone_does_not_have() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" 1111111111111111111111111111111111111111 HEAD) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
fatal: Invalid symmetric difference expression 1111111111111111111111111111111111111111...HEAD
ERR
  [ "$status" = 128 ] || {
    echo "exit $status, want 128" >&2
    exit 1
  }
}

it_prints_true_for_an_all_zero_base_without_reading_git() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/not-a-repo"

  (cd "$tree/not-a-repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" 0000000000000000000000000000000000000000 HEAD) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_with_gits_error_for_a_base_git_cannot_resolve() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" no-such-ref HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
fatal: ambiguous argument 'no-such-ref...HEAD': unknown revision or path not in the working tree.
Use '--' to separate paths from revisions, like this:
'git <command> [<revision>...] -- [<file>...]'
ERR
  [ "$status" = 128 ] || {
    echo "exit $status, want 128" >&2
    exit 1
  }
}

it_rejects_a_call_without_two_arguments_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: needs-nixos-checks.sh <base> <head>'
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

# Runtime every case needs: a git repository on main, with the identity the cases commit with in
# its own config. Each case commits the files its scenario starts from.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp" "$tree/repo"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" init -q -b main
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" config user.name fixture
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" config user.email fixture@example.invalid
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # the case's trap removes it
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves before a case commits anything of its own
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
