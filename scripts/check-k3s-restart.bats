#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for check-k3s-restart.sh: it passes, with no output, a dry-activate that leaves
# k3s.service alone, holds one whose stop or restart list holds k3s.service, lets a planned k3s
# window through with --allow-k3s-restart, and never reads k3s.service on the start line, on the
# "would NOT stop" line or inside another unit's name as a restart. Each case writes the
# dry-activate text inline, in switch-to-configuration-ng's line forms (create-stub-nixos-ssh.sh
# records their source), and runs the script under `env -i`.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/check-k3s-restart.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# setup_test <tree>: the home and temp folders the cases run with
setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp"
}

@test "it passes with no output a switch that leaves k3s alone" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" << 'EOF'
would stop the following units: alloy.service, atc-daemon.service
would activate the configuration...
would reload the following units: dbus.service
would restart the following units: tailscaled.service
would start the following units: alloy.service, atc-daemon.service
EOF

  refute_output
  refute_stderr
}

@test "it holds a switch that would stop k3s" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" << 'EOF'
would stop the following units: alloy.service, k3s.service, var-lib-rancher.mount
would activate the configuration...
would start the following units: alloy.service, k3s.service, var-lib-rancher.mount
EOF

  refute_output
  assert_stderr - << 'EOF'
the switch would interrupt k3s.service, and nixie can stay down for minutes after it:
would stop the following units: alloy.service, k3s.service, var-lib-rancher.mount
switch in a planned k3s window with --allow-k3s-restart
EOF
}

@test "it holds a switch that would restart k3s" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" << 'EOF'
would activate the configuration...
would restart the following units: k3s.service
EOF

  refute_output
  assert_stderr - << 'EOF'
the switch would interrupt k3s.service, and nixie can stay down for minutes after it:
would restart the following units: k3s.service
switch in a planned k3s window with --allow-k3s-restart
EOF
}

@test "it lets a k3s restart through in a planned k3s window" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" --allow-k3s-restart << 'EOF'
would stop the following units: k3s.service
would activate the configuration...
would restart the following units: atc-daemon.service, k3s.service
would start the following units: k3s.service
EOF

  assert_output - << 'EOF'
== k3s.service restarts in this planned k3s window (--allow-k3s-restart):
would stop the following units: k3s.service
would restart the following units: atc-daemon.service, k3s.service
EOF
  refute_stderr
}

# a stopped k3s that the switch starts, and a changed k3s with restartIfChanged off, both keep
# the running k3s up
@test "it passes k3s on the start line or the would not stop line" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" << 'EOF'
would NOT stop the following changed units: k3s.service
would activate the configuration...
would start the following units: k3s.service
EOF

  refute_output
  refute_stderr
}

@test "it never reads another unit whose name holds k3s as k3s" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" << 'EOF'
would stop the following units: k3s-reset.service, my-k3s.service
would activate the configuration...
would restart the following units: k3s.service.d.mount, k3s.socket
EOF

  refute_output
  refute_stderr
}

@test "it rejects an unknown argument with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" --allow-k3s < /dev/null

  refute_output
  assert_stderr 'usage: check-k3s-restart.sh [--allow-k3s-restart] < <dry-activate output>'
}
