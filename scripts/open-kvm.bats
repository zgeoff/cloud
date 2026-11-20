#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for open-kvm.sh: through a sudo stand-in (scripts/src/test-utils/shell/create-stub-kvm-sudo.sh) that
# runs nothing as root, it writes the udev rule that opens /dev/kvm to every user, then reloads
# udev's rules and triggers the device, in that order; a sudo that needs a password fails it with
# sudo's error before any udev call. Each case runs the script under `env -i` and compares its
# whole stdout, stderr, the rule written and the sudo call log.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-kvm-sudo.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/open-kvm.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# setup_test <tree>: the sudo stand-in in <tree>/bin, and the home and temp folders the script
# runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_kvm_sudo "$tree/bin"
}

@test "it writes the rule then reloads and triggers udev" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$script"

  assert_output 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"'
  refute_stderr

  run -0 diff - "$tree/rules" <<< 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"'
  run -0 diff - "$tree/calls" << 'EOF'
["sudo","tee","/etc/udev/rules.d/99-kvm4all.rules"]
["sudo","udevadm","control","--reload-rules"]
["sudo","udevadm","trigger","--name-match=kvm"]
EOF
}

@test "it fails with the sudo error before any udev call when sudo needs a password" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SUDO_DENIED=1 bash "$script"

  refute_output
  assert_stderr - << 'EOF'
sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper
sudo: a password is required
EOF

  run -0 diff - "$tree/calls" <<< '["sudo","tee","/etc/udev/rules.d/99-kvm4all.rules"]'
}
