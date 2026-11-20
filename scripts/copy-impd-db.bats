#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Hermetic test for copy-impd-db.sh: it checks the label, then runs `copy-impd-db-host <label>`
# on root@geoffcloud or the host IMPD_DB_HOST names, with nothing on ssh's stdin, and passes the
# host's report and exit code through. It touches no host: ssh is a stand-in from
# scripts/src/test-utils/shell that logs its argv as a JSON line and its stdin, and answers as the host
# does without running the host's tool, which needs root, Podman and the imp-host container;
# nixos/checks/impd-restore.nix runs that tool in the restore VM. One case hands ssh to the
# real ssh, refused by a dead loopback port. Each case runs the script under `env -i` with
# only the variables it sets and compares its whole stdout, stderr, call log and the stdin it
# sent, and its exact exit code.
#
#   bash scripts/run-bats.sh
#   CASE='label' bash scripts/run-bats.sh   # the cases whose title holds it

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-impd-db-ssh.sh'
  load 'src/test-utils/shell/create-stub-remote-tools.sh'
  load 'src/test-utils/shell/require-remote-tool-stubs.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# Runtime every case needs: the script in <tree>, the ssh stand-in with fail-closed
# stand-ins for the other remote tools in <tree>/bin, checked so no call can reach a real
# remote tool, the empty call log, and the HOME and TMPDIR the script runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  cp "$BATS_TEST_DIRNAME/copy-impd-db.sh" "$tree/"
  create_stub_impd_db_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

@test "it sends the copy to geoffcloud with the label and prints the hosts report" {
  setup_test "$tree"
  printf '%s\n' '["ssh","-o","BatchMode=yes","root@geoffcloud","copy-impd-db-host imp-0.29.0-pre-0.30.0"]' > "$tree/calls-expected"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash copy-impd-db.sh imp-0.29.0-pre-0.30.0

  assert_output - << 'OUT'
path /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000/imp.sqlite
sizeBytes 73728
lastMigration 0002_tokens
impVersion 0.29.0
createdAt 2026-10-08T12:00:00Z
integrity ok
image ghcr.io/zgeoff/imp-host:0.29.0@sha256:9b1f6c3e0a4d7f2b8c5e1a6d3f0b9c2e7a4d1f8b5c2e9a6d3f0c7b4e1a8d5f2b
copy: /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000 (73728 bytes, mode 600)
OUT
  refute_stderr

  run -0 diff "$tree/calls-expected" "$tree/calls"
  run -0 diff /dev/null "$tree/stdin"
}

@test "it sends the copy to the host IMPD DB HOST names" {
  setup_test "$tree"
  printf '%s\n' '["ssh","-o","BatchMode=yes","root@imp-staging","copy-impd-db-host imp-0.29.0-pre-0.30.0"]' > "$tree/calls-expected"

  run -0 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@imp-staging IMPD_DB_HOST=root@imp-staging bash copy-impd-db.sh imp-0.29.0-pre-0.30.0

  assert_output - << 'OUT'
path /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000/imp.sqlite
sizeBytes 73728
lastMigration 0002_tokens
impVersion 0.29.0
createdAt 2026-10-08T12:00:00Z
integrity ok
image ghcr.io/zgeoff/imp-host:0.29.0@sha256:9b1f6c3e0a4d7f2b8c5e1a6d3f0b9c2e7a4d1f8b5c2e9a6d3f0c7b4e1a8d5f2b
copy: /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000 (73728 bytes, mode 600)
OUT
  refute_stderr

  run -0 diff "$tree/calls-expected" "$tree/calls"
  run -0 diff /dev/null "$tree/stdin"
}

@test "it exits 1 with the hosts report when the copy fails its integrity check" {
  setup_test "$tree"
  printf '%s\n' '["ssh","-o","BatchMode=yes","root@geoffcloud","copy-impd-db-host imp-0.29.0-pre-0.30.0"]' > "$tree/calls-expected"

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_COPY_FAIL=integrity bash copy-impd-db.sh imp-0.29.0-pre-0.30.0

  assert_output - << 'OUT'
path /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000/imp.sqlite
sizeBytes 73728
lastMigration 0002_tokens
impVersion 0.29.0
createdAt 2026-10-08T12:00:00Z
integrity wrong # of entries in index sqlite_autoindex_imps_1; row 1 missing from index sqlite_autoindex_imps_1; row 2 missing from index sqlite_autoindex_imps_1; row 3 missing from index sqlite_autoindex_imps_1
image ghcr.io/zgeoff/imp-host:0.29.0@sha256:9b1f6c3e0a4d7f2b8c5e1a6d3f0b9c2e7a4d1f8b5c2e9a6d3f0c7b4e1a8d5f2b
copy: /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000 (73728 bytes, mode 600)
OUT
  refute_stderr

  run -0 diff "$tree/calls-expected" "$tree/calls"
  run -0 diff /dev/null "$tree/stdin"
}

@test "it exits 125 with podmans error when imp host is not running" {
  setup_test "$tree"
  printf '%s\n' '["ssh","-o","BatchMode=yes","root@geoffcloud","copy-impd-db-host imp-0.29.0-pre-0.30.0"]' > "$tree/calls-expected"

  run -125 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_COPY_FAIL=imp-host-stopped bash copy-impd-db.sh imp-0.29.0-pre-0.30.0

  refute_output
  assert_stderr 'Error: no container with name or ID "imp-host" found: no such container'

  run -0 diff "$tree/calls-expected" "$tree/calls"
  run -0 diff /dev/null "$tree/stdin"
}

@test "it fails with ssh exit 255 when the host refuses the connection" {
  setup_test "$tree"
  printf '%s\n' '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","copy-impd-db-host imp-0.29.0-pre-0.30.0"]' > "$tree/calls-expected"

  run -255 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_SSH_PASS=1 IMPD_DB_HOST=ssh://root@127.0.0.1:1 bash copy-impd-db.sh imp-0.29.0-pre-0.30.0

  refute_output
  assert_stderr $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'

  run -0 diff "$tree/calls-expected" "$tree/calls"
}

@test "it stops with exit 1 and its usage before any call when no label is given" {
  setup_test "$tree"

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash copy-impd-db.sh

  refute_output
  assert_stderr 'copy-impd-db.sh: line 17: 1: usage: copy-impd-db.sh <label>, such as imp-0.29.0-pre-0.30.0'

  run -0 diff /dev/null "$tree/calls"
}

@test "it stops with exit 1 before any call when the label holds another character" {
  setup_test "$tree"

  run -1 --separate-stderr env -C "$tree" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash copy-impd-db.sh '../imp 0.29'

  refute_output
  assert_stderr "the label may hold only letters, digits, '.', '_' and '-'"

  run -0 diff /dev/null "$tree/calls"
}
