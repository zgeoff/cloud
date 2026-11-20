#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-impd-db-ssh.sh: the ssh stand-in keeps what it was sent on stdin and
# answers the copy-impd-db-host command with the host's report for its label, or with the
# integrity or stopped-container failure it is told to give, never runs what it reads, fails
# closed on anything else, and hands a loopback call to the real ssh when asked. The pass-through cases pin what the suite
# assumes about the real ssh: a refused connection exits 255 with "ssh: connect to host …
# port …: Connection refused" and the CR LF that its log ends a line with on stderr, as
# OpenSSH 9.6p1 (CI's ubuntu-24.04 runner image 20261004) and 10.5p1 print it.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-impd-db-ssh.sh'
  load 'create-stub-remote-tools.sh'
  load 'require-remote-tool-stubs.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# Runtime every case needs: the stand-in in <tree>/bin, with fail-closed stand-ins for the
# other remote tools, checked so no call can reach a real remote tool, the empty call log,
# and the HOME and TMPDIR the stand-in runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_impd_db_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

@test "it answers the copy with the hosts report for its label without running it" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes root@geoffcloud "copy-impd-db-host pre-x" <<< "touch $tree/ran"

  assert_output - << 'OUT'
path /root/imp-db-backups/pre-x-20261008T120000/imp.sqlite
sizeBytes 73728
lastMigration 0002_tokens
impVersion 0.29.0
createdAt 2026-10-08T12:00:00Z
integrity ok
image ghcr.io/zgeoff/imp-host:0.29.0@sha256:9b1f6c3e0a4d7f2b8c5e1a6d3f0b9c2e7a4d1f8b5c2e9a6d3f0c7b4e1a8d5f2b
copy: /root/imp-db-backups/pre-x-20261008T120000 (73728 bytes, mode 600)
OUT
  refute_stderr
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","copy-impd-db-host pre-x"]'
  diff - "$tree/stdin" <<< "touch $tree/ran"
  refute [ -e "$tree/ran" ]
  refute [ -L "$tree/ran" ]
}

@test "it answers a failed integrity check with its findings on one line and exit 1" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_COPY_FAIL=integrity ssh -o BatchMode=yes root@geoffcloud "copy-impd-db-host pre-x" < /dev/null

  assert_output - << 'OUT'
path /root/imp-db-backups/pre-x-20261008T120000/imp.sqlite
sizeBytes 73728
lastMigration 0002_tokens
impVersion 0.29.0
createdAt 2026-10-08T12:00:00Z
integrity wrong # of entries in index sqlite_autoindex_imps_1; row 1 missing from index sqlite_autoindex_imps_1; row 2 missing from index sqlite_autoindex_imps_1; row 3 missing from index sqlite_autoindex_imps_1
image ghcr.io/zgeoff/imp-host:0.29.0@sha256:9b1f6c3e0a4d7f2b8c5e1a6d3f0b9c2e7a4d1f8b5c2e9a6d3f0c7b4e1a8d5f2b
copy: /root/imp-db-backups/pre-x-20261008T120000 (73728 bytes, mode 600)
OUT
  refute_stderr
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","copy-impd-db-host pre-x"]'
}

@test "it answers a stopped imp host with podmans error and exit 125" {
  setup_test "$tree"

  run -125 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_COPY_FAIL=imp-host-stopped ssh -o BatchMode=yes root@geoffcloud "copy-impd-db-host pre-x" \
    < /dev/null

  refute_output
  assert_stderr 'Error: no container with name or ID "imp-host" found: no such container'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","copy-impd-db-host pre-x"]'
}

@test "it fails closed with exit 97 on a call without batch mode" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh root@geoffcloud "copy-impd-db-host pre-x"

  refute_output
  assert_stderr 'unexpected: root@geoffcloud copy-impd-db-host pre-x'
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","copy-impd-db-host pre-x"]'
}

@test "it fails closed with exit 97 on another host" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes root@other "copy-impd-db-host pre-x"

  refute_output
  assert_stderr 'unexpected: -o BatchMode=yes root@other copy-impd-db-host pre-x'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@other","copy-impd-db-host pre-x"]'
}

@test "it fails closed with exit 97 on another command" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes root@geoffcloud systemctl stop imp-host

  refute_output
  assert_stderr 'unexpected: -o BatchMode=yes root@geoffcloud systemctl stop imp-host'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","stop","imp-host"]'
}

@test "it fails closed with exit 97 on a label with another character" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes root@geoffcloud "copy-impd-db-host ../x"

  refute_output
  assert_stderr 'unexpected: -o BatchMode=yes root@geoffcloud copy-impd-db-host ../x'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","copy-impd-db-host ../x"]'
}

@test "it hands a loopback call to the real ssh which refuses a dead port with exit 255" {
  setup_test "$tree"

  run -255 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "copy-impd-db-host x"

  refute_output
  assert_stderr $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","copy-impd-db-host x"]'
}

# 127.0.0.2 is loopback too, so a broken guard would only reach a dead local port, never a
# real host; the guard admits 127.0.0.1 alone.
@test "it never hands a call to another destination to the real ssh" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.2:1 "copy-impd-db-host x"

  refute_output
  assert_stderr 'unexpected: -o BatchMode=yes ssh://root@127.0.0.2:1 copy-impd-db-host x'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.2:1","copy-impd-db-host x"]'
}

# OpenSSH reads an option even after the destination, so the stand-in refuses one there
# before it calls the real ssh.
@test "it never hands a call with an option after the destination to the real ssh" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false "copy-impd-db-host x"

  refute_output
  assert_stderr 'unexpected: -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false copy-impd-db-host x'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","-oProxyCommand=false","copy-impd-db-host x"]'
}

@test "it hands a call to the system ssh not one on the callers PATH" {
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/fake"
  : > "$tree/calls"
  printf '#!/usr/bin/env bash\necho fake ssh\n' > "$tree/fake/ssh"
  chmod +x "$tree/fake/ssh"
  PATH="$tree/fake:$PATH" create_stub_impd_db_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"

  run -255 --separate-stderr env -i PATH="$tree/bin:$tree/fake:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "copy-impd-db-host x"

  refute_output
  assert_stderr $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","copy-impd-db-host x"]'
}
