#!/usr/bin/env bash
# Test for create-stub-bash-ssh.sh: the ssh stand-in runs one `bash -c` remote command here,
# with the host's stand-ins first on PATH and its own stdin, returns its exit code, fails
# closed on anything else or when a remote tool could reach the real one, and hands a
# loopback call to the real ssh when asked. The pass-through cases pin what the suites
# assume about the real ssh: a refused connection exits 255 with "ssh: connect to host …
# port …: Connection refused" and the CR LF that its log ends a line with on stderr, as
# OpenSSH 9.6p1 (CI's ubuntu-24.04 runner image 20261004) and 10.5p1 print it.
#
#   bash scripts/test-lib/test-create-stub-bash-ssh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-bash-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_runs_the_command_here_with_its_stdin_and_the_hosts_PATH() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '#!/usr/bin/env bash\necho "host tool: $*"\n' > "$tree/host-bin/host-tool"
  chmod +x "$tree/host-bin/host-tool"

  printf 'from stdin\n' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud "bash -c 'read -r line; host-tool \"\$1\" \"\$line\"; exit 3' _ arg" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'host tool: arg from stdin'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","bash -c 'read -r line; host-tool \"$1\" \"$line\"; exit 3' _ arg"]
CALLS
  [ "$status" = 3 ] || { echo "exit $status, want 3" >&2; exit 1; }
}

it_forwards_none_of_the_callers_environment() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud "bash -c 'printenv STUB_TREE'" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","bash -c 'printenv STUB_TREE'"]
CALLS
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_runs_the_command_from_the_host_directory_with_a_HOME_inside_it() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/tmp" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud "bash -c 'pwd; printenv HOME; ls -A \"\$HOME\"'") \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << OUT
$tree/host
$tree/host/root
OUT
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","bash -c 'pwd; printenv HOME; ls -A \"$HOME\"'"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_a_call_without_batch_mode() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh root@geoffcloud "bash -c 'touch $tree/ran'" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: root@geoffcloud bash -c 'touch $tree/ran'"
  diff - "$tree/calls" <<< "[\"ssh\",\"root@geoffcloud\",\"bash -c 'touch $tree/ran'\"]"
  [ ! -e "$tree/ran" ] || { echo "the command ran" >&2; exit 1; }
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_another_host() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@other "bash -c 'touch $tree/ran'" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: -o BatchMode=yes root@other bash -c 'touch $tree/ran'"
  diff - "$tree/calls" <<< "[\"ssh\",\"-o\",\"BatchMode=yes\",\"root@other\",\"bash -c 'touch $tree/ran'\"]"
  [ ! -e "$tree/ran" ] || { echo "the command ran" >&2; exit 1; }
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_a_command_that_is_not_one_bash_c_argument() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud touch "$tree/ran" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: -o BatchMode=yes root@geoffcloud touch $tree/ran"
  diff - "$tree/calls" <<< "[\"ssh\",\"-o\",\"BatchMode=yes\",\"root@geoffcloud\",\"touch\",\"$tree/ran\"]"
  [ ! -e "$tree/ran" ] || { echo "the command ran" >&2; exit 1; }
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_a_command_that_names_a_remote_tool() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud "bash -c 'touch $tree/ran; /usr/bin/rsync x y'" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: -o BatchMode=yes root@geoffcloud bash -c 'touch $tree/ran; /usr/bin/rsync x y'"
  diff - "$tree/calls" <<< "[\"ssh\",\"-o\",\"BatchMode=yes\",\"root@geoffcloud\",\"bash -c 'touch $tree/ran; /usr/bin/rsync x y'\"]"
  [ ! -e "$tree/ran" ] || { echo "the command ran" >&2; exit 1; }
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_when_a_remote_tool_on_the_host_PATH_is_not_a_stand_in() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/host-bin/tailscale"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud "bash -c 'touch $tree/ran'" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: tailscale on the host PATH is not a stand-in in $tree/host-bin"
  diff - "$tree/calls" <<< "[\"ssh\",\"-o\",\"BatchMode=yes\",\"root@geoffcloud\",\"bash -c 'touch $tree/ran'\"]"
  [ ! -e "$tree/ran" ] || { echo "the command ran" >&2; exit 1; }
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_hands_a_loopback_call_to_the_real_ssh_which_refuses_a_dead_port_with_exit_255() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "bash -c true" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","bash -c true"]'
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

# 127.0.0.2 is loopback too, so a broken guard would only reach a dead local port, never a
# real host; the guard admits 127.0.0.1 alone.
it_never_hands_a_call_to_another_destination_to_the_real_ssh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.2:1 "bash -c true" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes ssh://root@127.0.0.2:1 bash -c true'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.2:1","bash -c true"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# OpenSSH reads an option even after the destination, so the stand-in refuses one there
# before it calls the real ssh.
it_never_hands_a_call_with_an_option_after_the_destination_to_the_real_ssh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false "bash -c true" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false bash -c true'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","-oProxyCommand=false","bash -c true"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_hands_a_call_to_the_system_ssh_not_one_on_the_callers_PATH() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/fake"
  : > "$tree/calls"
  printf '#!/usr/bin/env bash\necho fake ssh\n' > "$tree/fake/ssh"
  chmod +x "$tree/fake/ssh"
  PATH="$tree/fake:$PATH" create_stub_bash_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"

  env -i PATH="$tree/bin:$tree/fake:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "bash -c true" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","bash -c true"]'
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin and fail-closed stand-ins for the
# other remote tools there and for every remote tool in the host's <tree>/host-bin, each
# checked so no call can reach a real remote tool, the empty call log, and the HOME and
# TMPDIR the stand-in runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/host-bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_bash_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  create_stub_remote_tools "$tree/host-bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
  require_remote_tool_stubs "$tree/host-bin"
}

run_cases
