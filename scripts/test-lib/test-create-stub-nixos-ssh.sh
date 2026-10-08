#!/usr/bin/env bash
# Test for create-stub-nixos-ssh.sh: the ssh stand-in logs every call, answers the three
# remote commands of a switch, fails closed on anything else, and hands a loopback call to
# the real ssh when asked. The pass-through case pins what the switch suite assumes about
# the real ssh: a refused connection exits 255 with "ssh: connect to host … port …:
# Connection refused" and the CR LF that its log ends a line with on stderr, as OpenSSH
# 9.6p1 (CI's ubuntu-24.04 runner image 20261004) and 10.5p1 print it. A session that
# drops after it opens has no real transport here, so the stand-in's drop reuses that exit
# 255 with OpenSSH's "Connection to <host> closed by remote host." line, whose source and
# check create-stub-nixos-ssh.sh records with those of the other texts it prints.
#
#   bash scripts/test-lib/test-create-stub-nixos-ssh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-nixos-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_answers_the_switch_with_nothing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" ssh -o BatchMode=yes root@geoffcloud \
    "nix-env -p /nix/var/nix/profiles/system --set '/nix/store/x' && systemd-run '/nix/store/x/bin/switch-to-configuration' switch" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/x' && systemd-run '/nix/store/x/bin/switch-to-configuration' switch"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# switch-to-configuration-ng sorts the failed units by their lower-case names, so
# Atc-daemon.service comes between alloy.service and zram.service, not first as a byte
# order would put it.
it_fails_the_switch_as_switch_to_configuration_ng_reports_failed_units() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_ACTIVATE_FAILED_UNITS="zram.service Atc-daemon.service alloy.service" \
    STUB_ACTIVATE_STATUS=$'× alloy.service - Alloy\n     Active: failed (Result: exit-code)' \
    ssh -o BatchMode=yes root@geoffcloud \
    "nix-env -p /nix/var/nix/profiles/system --set '/nix/store/x' && systemd-run '/nix/store/x/bin/switch-to-configuration' switch" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
× alloy.service - Alloy
     Active: failed (Result: exit-code)
OUT
  diff - "$tree/err" <<< 'warning: the following units failed: alloy.service, Atc-daemon.service, zram.service'
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/x' && systemd-run '/nix/store/x/bin/switch-to-configuration' switch"]
CALLS
  [ "$status" = 4 ] || { echo "exit $status, want 4" >&2; exit 1; }
}

it_prints_no_status_text_for_failed_units_when_none_is_given() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_ACTIVATE_FAILED_UNITS="alloy.service" \
    ssh -o BatchMode=yes root@geoffcloud \
    "nix-env -p /nix/var/nix/profiles/system --set '/nix/store/x' && systemd-run '/nix/store/x/bin/switch-to-configuration' switch" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'warning: the following units failed: alloy.service'
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/x' && systemd-run '/nix/store/x/bin/switch-to-configuration' switch"]
CALLS
  [ "$status" = 4 ] || { echo "exit $status, want 4" >&2; exit 1; }
}

it_prints_the_named_current_system_for_readlink() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CURRENT=/nix/store/current \
    ssh -o BatchMode=yes root@geoffcloud readlink /run/current-system \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< /nix/store/current
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_drops_the_connection_at_readlink_with_exit_255() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CURRENT=/nix/store/current \
    STUB_SSH_DROP_AT_READLINK=1 ssh -o BatchMode=yes root@geoffcloud readlink /run/current-system \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'Connection to geoffcloud closed by remote host.\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]'
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_prints_the_named_failed_units() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_FAILED_UNITS='alloy.service loaded failed failed Alloy' \
    ssh -o BatchMode=yes root@geoffcloud systemctl --failed --no-legend --plain \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'alloy.service loaded failed failed Alloy'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_the_failed_unit_listing_with_the_named_exit_code() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_FAILED_EXIT=1 \
    ssh -o BatchMode=yes root@geoffcloud systemctl --failed --no-legend --plain \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Failed to list units: Connection timed out'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_an_unknown_remote_command() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    ssh -o BatchMode=yes root@geoffcloud reboot > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes root@geoffcloud reboot'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","reboot"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_a_call_without_batch_mode() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CURRENT=/nix/store/current \
    ssh root@geoffcloud readlink /run/current-system > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: root@geoffcloud readlink /run/current-system'
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","readlink","/run/current-system"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_hands_a_loopback_call_to_the_real_ssh_which_refuses_a_dead_port_with_exit_255() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 true \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","true"]'
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

# 127.0.0.2 is loopback too, so a broken guard would only reach a dead local port, never a
# real host; the guard admits 127.0.0.1 alone.
it_never_hands_a_call_to_another_destination_to_the_real_ssh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.2:1 true \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes ssh://root@127.0.0.2:1 true'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.2:1","true"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# OpenSSH reads an option even after the destination, so the stand-in refuses one there
# before it calls the real ssh.
it_never_hands_a_call_with_an_option_after_the_destination_to_the_real_ssh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false true \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false true'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","-oProxyCommand=false","true"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_hands_a_call_to_the_system_ssh_not_one_on_the_callers_PATH() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/fake"
  printf '#!/usr/bin/env bash\necho fake ssh\n' > "$tree/fake/ssh"
  chmod +x "$tree/fake/ssh"
  PATH="$tree/fake:$PATH" create_stub_nixos_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"

  env -i PATH="$tree/bin:$tree/fake:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 true \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","true"]'
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, with fail-closed stand-ins for the other
# remote tools, checked so no call can reach a real remote tool, and the HOME and TMPDIR the
# stand-in runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_nixos_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
