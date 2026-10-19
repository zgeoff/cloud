#!/usr/bin/env bash
# Test for create-stub-kvm-sudo.sh: the sudo stand-in writes the rule tee gets into the case tree
# and prints it, answers the two udevadm calls with nothing, logs every call, answers every call as
# sudo does without a password when told to, and fails closed on any other call.
#
#   bash test-support/shell/test-create-stub-kvm-sudo.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-kvm-sudo.sh"

it_writes_the_rule_into_the_case_tree_and_prints_it_as_tee_does() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    sudo tee /etc/udev/rules.d/99-kvm4all.rules <<< 'KERNEL=="kvm"' > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'KERNEL=="kvm"'
  diff /dev/null "$tree/err"
  diff - "$tree/rules" <<< 'KERNEL=="kvm"'
  diff - "$tree/calls" <<< '["sudo","tee","/etc/udev/rules.d/99-kvm4all.rules"]'
  assert_status 0 "$status"
}

it_answers_the_udev_reload_with_nothing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    sudo udevadm control --reload-rules > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["sudo","udevadm","control","--reload-rules"]'
  assert_status 0 "$status"
}

it_answers_the_udev_trigger_with_nothing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    sudo udevadm trigger --name-match=kvm > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["sudo","udevadm","trigger","--name-match=kvm"]'
  assert_status 0 "$status"
}

it_answers_as_sudo_does_without_a_password_when_denied() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SUDO_DENIED=1 sudo tee /etc/udev/rules.d/99-kvm4all.rules <<< 'KERNEL=="kvm"' > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper
sudo: a password is required
EOF
  [ ! -e "$tree/rules" ] || {
    echo "the denied tee wrote the rule" >&2
    exit 1
  }
  diff - "$tree/calls" <<< '["sudo","tee","/etc/udev/rules.d/99-kvm4all.rules"]'
  assert_status 1 "$status"
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    sudo tee /etc/udev/rules.d/other.rules < /dev/null > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: tee /etc/udev/rules.d/other.rules'
  diff - "$tree/calls" <<< '["sudo","tee","/etc/udev/rules.d/other.rules"]'
  assert_status 97 "$status"
}

# setup_test <tree>: the sudo stand-in in <tree>/bin, and the home and temp folders it runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_kvm_sudo "$tree/bin"
}

run_cases
