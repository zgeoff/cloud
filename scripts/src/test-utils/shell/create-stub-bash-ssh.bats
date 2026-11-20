#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-bash-ssh.sh: the ssh stand-in runs one `bash -c` remote command here,
# with the host's stand-ins first on PATH and its own stdin, returns its exit code, fails
# closed on anything else or when a remote tool could reach the real one, and hands a
# loopback call to the real ssh when asked. The pass-through cases pin what the suites
# assume about the real ssh: a refused connection exits 255 with "ssh: connect to host …
# port …: Connection refused" and the CR LF that its log ends a line with on stderr, as
# OpenSSH 9.6p1 (CI's ubuntu-24.04 runner image 20261004) and 10.5p1 print it.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-bash-ssh.sh'
  load 'create-stub-remote-tools.sh'
  load 'require-remote-tool-stubs.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# in_dir <dir> <command…>: runs the command from <dir>
in_dir() {
  cd "$1" && shift && "$@"
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

@test "it runs the command here with its stdin and the hosts PATH" {
  setup_test "$tree"
  printf '#!/usr/bin/env bash\necho "host tool: $*"\n' > "$tree/host-bin/host-tool"
  chmod +x "$tree/host-bin/host-tool"

  run -3 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud "bash -c 'read -r line; host-tool \"\$1\" \"\$line\"; exit 3' _ arg" <<< 'from stdin'

  assert_output 'host tool: arg from stdin'
  refute_stderr
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","bash -c 'read -r line; host-tool \"$1\" \"$line\"; exit 3' _ arg"]
CALLS
}

@test "it forwards none of the callers environment" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud "bash -c 'printenv STUB_TREE'"

  refute_output
  refute_stderr
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","bash -c 'printenv STUB_TREE'"]
CALLS
}

@test "it runs the command from the host directory with a HOME inside it" {
  setup_test "$tree"

  run -0 --separate-stderr in_dir "$tree/tmp" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud "bash -c 'pwd; printenv HOME; ls -A \"\$HOME\"'"

  assert_output - << OUT
$tree/host
$tree/host/root
OUT
  refute_stderr
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","bash -c 'pwd; printenv HOME; ls -A \"$HOME\"'"]
CALLS
}

@test "it fails closed with exit 97 on a call without batch mode" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh root@geoffcloud "bash -c 'touch $tree/ran'"

  refute_output
  assert_stderr "unexpected: root@geoffcloud bash -c 'touch $tree/ran'"
  diff - "$tree/calls" <<< "[\"ssh\",\"root@geoffcloud\",\"bash -c 'touch $tree/ran'\"]"
  refute [ -e "$tree/ran" ]
  refute [ -L "$tree/ran" ]
}

@test "it fails closed with exit 97 on another host" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@other "bash -c 'touch $tree/ran'"

  refute_output
  assert_stderr "unexpected: -o BatchMode=yes root@other bash -c 'touch $tree/ran'"
  diff - "$tree/calls" <<< "[\"ssh\",\"-o\",\"BatchMode=yes\",\"root@other\",\"bash -c 'touch $tree/ran'\"]"
  refute [ -e "$tree/ran" ]
  refute [ -L "$tree/ran" ]
}

@test "it fails closed with exit 97 on a command that is not one bash c argument" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud touch "$tree/ran"

  refute_output
  assert_stderr "unexpected: -o BatchMode=yes root@geoffcloud touch $tree/ran"
  diff - "$tree/calls" <<< "[\"ssh\",\"-o\",\"BatchMode=yes\",\"root@geoffcloud\",\"touch\",\"$tree/ran\"]"
  refute [ -e "$tree/ran" ]
  refute [ -L "$tree/ran" ]
}

@test "it fails closed with exit 97 on one remote argument that is not bash c" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud "touch $tree/ran"

  refute_output
  assert_stderr "unexpected: -o BatchMode=yes root@geoffcloud touch $tree/ran"
  diff - "$tree/calls" <<< "[\"ssh\",\"-o\",\"BatchMode=yes\",\"root@geoffcloud\",\"touch $tree/ran\"]"
  refute [ -e "$tree/ran" ]
  refute [ -L "$tree/ran" ]
}

@test "it fails closed with exit 97 on a command that names a remote tool" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud "bash -c 'touch $tree/ran; /usr/bin/rsync x y'"

  refute_output
  assert_stderr "unexpected: -o BatchMode=yes root@geoffcloud bash -c 'touch $tree/ran; /usr/bin/rsync x y'"
  diff - "$tree/calls" <<< "[\"ssh\",\"-o\",\"BatchMode=yes\",\"root@geoffcloud\",\"bash -c 'touch $tree/ran; /usr/bin/rsync x y'\"]"
  refute [ -e "$tree/ran" ]
  refute [ -L "$tree/ran" ]
}

@test "it fails closed with exit 97 when a remote tool on the host PATH is not a stand in" {
  setup_test "$tree"
  rm "$tree/host-bin/tailscale"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud "bash -c 'touch $tree/ran'"

  refute_output
  assert_stderr "unexpected: tailscale on the host PATH is not a stand-in in $tree/host-bin"
  diff - "$tree/calls" <<< "[\"ssh\",\"-o\",\"BatchMode=yes\",\"root@geoffcloud\",\"bash -c 'touch $tree/ran'\"]"
  refute [ -e "$tree/ran" ]
  refute [ -L "$tree/ran" ]
}

@test "it fails closed with exit 97 on a command that uses command p" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud "bash -c 'touch $tree/ran; command -p true'"

  refute_output
  assert_stderr "unexpected: -o BatchMode=yes root@geoffcloud bash -c 'touch $tree/ran; command -p true'"
  diff - "$tree/calls" <<< "[\"ssh\",\"-o\",\"BatchMode=yes\",\"root@geoffcloud\",\"bash -c 'touch $tree/ran; command -p true'\"]"
  refute [ -e "$tree/ran" ]
  refute [ -L "$tree/ran" ]
}

@test "it fails closed with exit 97 when a host stand in is not executable" {
  setup_test "$tree"
  chmod -x "$tree/host-bin/rsync"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ssh -o BatchMode=yes root@geoffcloud "bash -c 'touch $tree/ran'"

  refute_output
  assert_stderr "unexpected: rsync on the host PATH is not a stand-in in $tree/host-bin"
  diff - "$tree/calls" <<< "[\"ssh\",\"-o\",\"BatchMode=yes\",\"root@geoffcloud\",\"bash -c 'touch $tree/ran'\"]"
  refute [ -e "$tree/ran" ]
  refute [ -L "$tree/ran" ]
}

@test "it hands a loopback call to the real ssh which refuses a dead port with exit 255" {
  setup_test "$tree"

  run -255 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "bash -c true"

  refute_output
  assert_stderr $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","bash -c true"]'
}

# 127.0.0.2 is loopback too, so a broken guard would only reach a dead local port, never a
# real host; the guard admits 127.0.0.1 alone.
@test "it never hands a call to another destination to the real ssh" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.2:1 "bash -c true"

  refute_output
  assert_stderr 'unexpected: -o BatchMode=yes ssh://root@127.0.0.2:1 bash -c true'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.2:1","bash -c true"]'
}

# OpenSSH reads an option even after the destination, so the stand-in refuses one there
# before it calls the real ssh.
@test "it never hands a call with an option after the destination to the real ssh" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false "bash -c true"

  refute_output
  assert_stderr 'unexpected: -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false bash -c true'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","-oProxyCommand=false","bash -c true"]'
}

@test "it hands a call to the system ssh not one on the callers PATH" {
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/fake"
  : > "$tree/calls"
  printf '#!/usr/bin/env bash\necho fake ssh\n' > "$tree/fake/ssh"
  chmod +x "$tree/fake/ssh"
  PATH="$tree/fake:$PATH" create_stub_bash_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"

  run -255 --separate-stderr env -i PATH="$tree/bin:$tree/fake:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "bash -c true"

  refute_output
  assert_stderr $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","bash -c true"]'
}
