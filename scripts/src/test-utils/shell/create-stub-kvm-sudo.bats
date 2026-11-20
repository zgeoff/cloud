#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-kvm-sudo.sh: the sudo stand-in writes the rule tee gets into the case tree
# and prints it, answers the two udevadm calls with nothing, logs every call, answers every call as
# sudo does without a password when told to, and fails closed on any other call.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-kvm-sudo.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# setup_test <tree>: the sudo stand-in in <tree>/bin, and the home and temp folders it runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_kvm_sudo "$tree/bin"
}

@test "it writes the rule into the case tree and prints it as tee does" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    sudo tee /etc/udev/rules.d/99-kvm4all.rules <<< 'KERNEL=="kvm"'

  assert_output 'KERNEL=="kvm"'
  refute_stderr
  diff - "$tree/rules" <<< 'KERNEL=="kvm"'
  diff - "$tree/calls" <<< '["sudo","tee","/etc/udev/rules.d/99-kvm4all.rules"]'
}

@test "it answers the udev reload with nothing" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    sudo udevadm control --reload-rules

  refute_output
  refute_stderr
  diff - "$tree/calls" <<< '["sudo","udevadm","control","--reload-rules"]'
}

@test "it answers the udev trigger with nothing" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    sudo udevadm trigger --name-match=kvm

  refute_output
  refute_stderr
  diff - "$tree/calls" <<< '["sudo","udevadm","trigger","--name-match=kvm"]'
}

@test "it answers as sudo does without a password when denied" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SUDO_DENIED=1 sudo tee /etc/udev/rules.d/99-kvm4all.rules <<< 'KERNEL=="kvm"'

  refute_output
  assert_stderr - << 'EOF'
sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper
sudo: a password is required
EOF
  refute [ -e "$tree/rules" ]
  diff - "$tree/calls" <<< '["sudo","tee","/etc/udev/rules.d/99-kvm4all.rules"]'
}

@test "it fails closed with exit 97 on any other call" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    sudo tee /etc/udev/rules.d/other.rules < /dev/null

  refute_output
  assert_stderr 'unexpected: tee /etc/udev/rules.d/other.rules'
  diff - "$tree/calls" <<< '["sudo","tee","/etc/udev/rules.d/other.rules"]'
}
