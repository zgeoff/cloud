#!/usr/bin/env bash
# Test for open-kvm.sh: through a sudo stand-in (scripts/test-lib/create-stub-kvm-sudo.sh) that
# runs nothing as root, it writes the udev rule that opens /dev/kvm to every user, then reloads
# udev's rules and triggers the device, in that order; a sudo that needs a password fails it with
# sudo's error before any udev call. Each case runs the script under `env -i` and compares its
# whole stdout, stderr, the rule written and the sudo call log.
#
#   bash scripts/test-open-kvm.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-kvm-sudo.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/open-kvm.sh"

it_writes_the_rule_then_reloads_and_triggers_udev() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"'
  diff /dev/null "$tree/err"
  diff - "$tree/rules" <<< 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"'
  diff - "$tree/calls" << 'EOF'
["sudo","tee","/etc/udev/rules.d/99-kvm4all.rules"]
["sudo","udevadm","control","--reload-rules"]
["sudo","udevadm","trigger","--name-match=kvm"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_with_the_sudo_error_before_any_udev_call_when_sudo_needs_a_password() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SUDO_DENIED=1 bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper
sudo: a password is required
EOF
  diff - "$tree/calls" <<< '["sudo","tee","/etc/udev/rules.d/99-kvm4all.rules"]'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

# setup_test <tree>: the sudo stand-in in <tree>/bin, and the home and temp folders the script
# runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_kvm_sudo "$tree/bin"
}

run_cases
