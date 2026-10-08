#!/usr/bin/env bash
# Hermetic test for copy-impd-db.sh: it checks the label, then runs `bash -s -- <label>` on
# root@geoffcloud or the host IMPD_DB_HOST names, with copy-impd-db-host.sh on ssh's stdin,
# and passes the host's report and exit code through. It touches no host: ssh is a stand-in
# from test-lib that logs its argv as a JSON line and its stdin, and answers as the host does
# without running the host script, which needs root, Nix and the imp-host container;
# nixos/checks/impd-restore.nix runs that script in the restore VM. One case hands ssh to the
# real ssh, refused by a dead loopback port. Each case runs the script under `env -i` with
# only the variables it sets and compares its whole stdout, stderr, call log and the stdin it
# sent, and its exact exit code.
#
#   bash scripts/test-copy-impd-db.sh
#   CASE='label' bash scripts/test-copy-impd-db.sh   # the cases whose title holds it
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-impd-db-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/require-remote-tool-stubs.sh"

it_sends_the_copy_to_geoffcloud_with_the_label_and_prints_the_hosts_report() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '%s\n' '["ssh","-o","BatchMode=yes","root@geoffcloud","bash -s -- imp-0.29.0-pre-0.30.0"]' > "$tree/calls-expected"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash copy-impd-db.sh imp-0.29.0-pre-0.30.0) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
path /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000/imp.sqlite
sizeBytes 73728
lastMigration 0002_tokens
impVersion 0.29.0
createdAt 2026-10-08T12:00:00Z
integrity ok
image ghcr.io/zgeoff/imp-host:0.29.0@sha256:9b1f6c3e0a4d7f2b8c5e1a6d3f0b9c2e7a4d1f8b5c2e9a6d3f0c7b4e1a8d5f2b
copy: /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000 (73728 bytes, mode 600)
OUT
  diff /dev/null "$tree/err"
  diff "$tree/calls-expected" "$tree/calls"
  diff "$(dirname "${BASH_SOURCE[0]}")/copy-impd-db-host.sh" "$tree/stdin"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_sends_the_copy_to_the_host_IMPD_DB_HOST_names() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '%s\n' '["ssh","-o","BatchMode=yes","root@imp-staging","bash -s -- imp-0.29.0-pre-0.30.0"]' > "$tree/calls-expected"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@imp-staging IMPD_DB_HOST=root@imp-staging bash copy-impd-db.sh imp-0.29.0-pre-0.30.0) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
path /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000/imp.sqlite
sizeBytes 73728
lastMigration 0002_tokens
impVersion 0.29.0
createdAt 2026-10-08T12:00:00Z
integrity ok
image ghcr.io/zgeoff/imp-host:0.29.0@sha256:9b1f6c3e0a4d7f2b8c5e1a6d3f0b9c2e7a4d1f8b5c2e9a6d3f0c7b4e1a8d5f2b
copy: /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000 (73728 bytes, mode 600)
OUT
  diff /dev/null "$tree/err"
  diff "$tree/calls-expected" "$tree/calls"
  diff "$(dirname "${BASH_SOURCE[0]}")/copy-impd-db-host.sh" "$tree/stdin"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_exits_1_with_the_hosts_report_when_the_copy_fails_its_integrity_check() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '%s\n' '["ssh","-o","BatchMode=yes","root@geoffcloud","bash -s -- imp-0.29.0-pre-0.30.0"]' > "$tree/calls-expected"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_COPY_FAIL=integrity bash copy-impd-db.sh imp-0.29.0-pre-0.30.0) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
path /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000/imp.sqlite
sizeBytes 73728
lastMigration 0002_tokens
impVersion 0.29.0
createdAt 2026-10-08T12:00:00Z
integrity wrong # of entries in index sqlite_autoindex_imps_1
image ghcr.io/zgeoff/imp-host:0.29.0@sha256:9b1f6c3e0a4d7f2b8c5e1a6d3f0b9c2e7a4d1f8b5c2e9a6d3f0c7b4e1a8d5f2b
copy: /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000 (73728 bytes, mode 600)
OUT
  diff /dev/null "$tree/err"
  diff "$tree/calls-expected" "$tree/calls"
  diff "$(dirname "${BASH_SOURCE[0]}")/copy-impd-db-host.sh" "$tree/stdin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_exits_1_with_dockers_error_when_imp_host_is_not_running() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '%s\n' '["ssh","-o","BatchMode=yes","root@geoffcloud","bash -s -- imp-0.29.0-pre-0.30.0"]' > "$tree/calls-expected"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_COPY_FAIL=imp-host-stopped bash copy-impd-db.sh imp-0.29.0-pre-0.30.0) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error response from daemon: No such container: imp-host'
  diff "$tree/calls-expected" "$tree/calls"
  diff "$(dirname "${BASH_SOURCE[0]}")/copy-impd-db-host.sh" "$tree/stdin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_with_ssh_exit_255_when_the_host_refuses_the_connection() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '%s\n' '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","bash -s -- imp-0.29.0-pre-0.30.0"]' > "$tree/calls-expected"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_SSH_PASS=1 IMPD_DB_HOST=ssh://root@127.0.0.1:1 bash copy-impd-db.sh imp-0.29.0-pre-0.30.0) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff "$tree/calls-expected" "$tree/calls"
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_stops_with_exit_1_and_its_usage_before_any_call_when_no_label_is_given() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash copy-impd-db.sh) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'copy-impd-db.sh: line 15: 1: usage: copy-impd-db.sh <label>, such as imp-0.29.0-pre-0.30.0'
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_with_exit_1_before_any_call_when_the_label_holds_another_character() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash copy-impd-db.sh '../imp 0.29') \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "the label may hold only letters, digits, '.', '_' and '-'"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# Runtime every case needs: the script in <tree>, the ssh stand-in with fail-closed
# stand-ins for the other remote tools in <tree>/bin, checked so no call can reach a real
# remote tool, the empty call log, and the HOME and TMPDIR the script runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  cp "$(dirname "${BASH_SOURCE[0]}")/copy-impd-db.sh" "$(dirname "${BASH_SOURCE[0]}")/copy-impd-db-host.sh" "$tree/"
  create_stub_impd_db_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
