#!/usr/bin/env bash
# Test for check-k3s-restart.sh: it passes, with no output, a dry-activate that leaves
# k3s.service alone, holds one whose stop or restart list holds k3s.service, lets a planned k3s
# window through with --allow-k3s-restart, and never reads k3s.service on the start line, on the
# "would NOT stop" line or inside another unit's name as a restart. Each case writes the
# dry-activate text inline, in switch-to-configuration-ng's line forms (create-stub-nixos-ssh.sh
# records their source), and runs the script under `env -i`.
#
#   bash scripts/test-check-k3s-restart.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-k3s-restart.sh"

# setup_test <tree>: the home and temp folders the cases run with
setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp"
}

it_passes_with_no_output_a_switch_that_leaves_k3s_alone() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" \
    > "$tree/out" 2> "$tree/err" << 'EOF' || status=$?
would stop the following units: alloy.service, atc-daemon.service
would activate the configuration...
would reload the following units: dbus.service
would restart the following units: tailscaled.service
would start the following units: alloy.service, atc-daemon.service
EOF

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_holds_a_switch_that_would_stop_k3s() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" \
    > "$tree/out" 2> "$tree/err" << 'EOF' || status=$?
would stop the following units: alloy.service, k3s.service, var-lib-rancher.mount
would activate the configuration...
would start the following units: alloy.service, k3s.service, var-lib-rancher.mount
EOF

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
the switch would interrupt k3s.service, and nixie can stay down for minutes after it:
would stop the following units: alloy.service, k3s.service, var-lib-rancher.mount
switch in a planned k3s window with --allow-k3s-restart
EOF
  assert_status 1 "$status"
}

it_holds_a_switch_that_would_restart_k3s() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" \
    > "$tree/out" 2> "$tree/err" << 'EOF' || status=$?
would activate the configuration...
would restart the following units: k3s.service
EOF

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
the switch would interrupt k3s.service, and nixie can stay down for minutes after it:
would restart the following units: k3s.service
switch in a planned k3s window with --allow-k3s-restart
EOF
  assert_status 1 "$status"
}

it_lets_a_k3s_restart_through_in_a_planned_k3s_window() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" --allow-k3s-restart \
    > "$tree/out" 2> "$tree/err" << 'EOF' || status=$?
would stop the following units: k3s.service
would activate the configuration...
would restart the following units: atc-daemon.service, k3s.service
would start the following units: k3s.service
EOF

  diff - "$tree/out" << 'EOF'
== k3s.service restarts in this planned k3s window (--allow-k3s-restart):
would stop the following units: k3s.service
would restart the following units: atc-daemon.service, k3s.service
EOF
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

# a stopped k3s that the switch starts, and a changed k3s with restartIfChanged off, both keep
# the running k3s up
it_passes_k3s_on_the_start_line_or_the_would_not_stop_line() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" \
    > "$tree/out" 2> "$tree/err" << 'EOF' || status=$?
would NOT stop the following changed units: k3s.service
would activate the configuration...
would start the following units: k3s.service
EOF

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_never_reads_another_unit_whose_name_holds_k3s_as_k3s() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" \
    > "$tree/out" 2> "$tree/err" << 'EOF' || status=$?
would stop the following units: k3s-reset.service, my-k3s.service
would activate the configuration...
would restart the following units: k3s.service.d.mount, k3s.socket
EOF

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_rejects_an_unknown_argument_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" --allow-k3s \
    > "$tree/out" 2> "$tree/err" < /dev/null || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: check-k3s-restart.sh [--allow-k3s-restart] < <dry-activate output>'
  assert_status 2 "$status"
}

run_cases
