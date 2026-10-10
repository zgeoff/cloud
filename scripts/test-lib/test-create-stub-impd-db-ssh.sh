#!/usr/bin/env bash
# Test for create-stub-impd-db-ssh.sh: the ssh stand-in keeps the script it was sent on
# stdin and answers the copy command with the host's report for its label, or with the
# integrity or stopped-container failure it is told to give, never runs the script, fails
# closed on anything else, and hands a loopback call to the real ssh when asked. The pass-through cases pin what the suite
# assumes about the real ssh: a refused connection exits 255 with "ssh: connect to host …
# port …: Connection refused" and the CR LF that its log ends a line with on stderr, as
# OpenSSH 9.6p1 (CI's ubuntu-24.04 runner image 20261004) and 10.5p1 print it.
#
#   bash scripts/test-lib/test-create-stub-impd-db-ssh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-missing.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-impd-db-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_answers_the_copy_with_the_hosts_report_for_its_label_without_running_it() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes root@geoffcloud "bash -s -- pre-x" <<< "touch $tree/ran" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
path /root/imp-db-backups/pre-x-20261008T120000/imp.sqlite
sizeBytes 73728
lastMigration 0002_tokens
impVersion 0.29.0
createdAt 2026-10-08T12:00:00Z
integrity ok
image ghcr.io/zgeoff/imp-host:0.29.0@sha256:9b1f6c3e0a4d7f2b8c5e1a6d3f0b9c2e7a4d1f8b5c2e9a6d3f0c7b4e1a8d5f2b
copy: /root/imp-db-backups/pre-x-20261008T120000 (73728 bytes, mode 600)
OUT
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","bash -s -- pre-x"]'
  diff - "$tree/stdin" <<< "touch $tree/ran"
  assert_missing "$tree/ran" "the command ran"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_answers_a_failed_integrity_check_with_its_findings_on_one_line_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_COPY_FAIL=integrity ssh -o BatchMode=yes root@geoffcloud "bash -s -- pre-x" < /dev/null > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
path /root/imp-db-backups/pre-x-20261008T120000/imp.sqlite
sizeBytes 73728
lastMigration 0002_tokens
impVersion 0.29.0
createdAt 2026-10-08T12:00:00Z
integrity wrong # of entries in index sqlite_autoindex_imps_1; row 1 missing from index sqlite_autoindex_imps_1; row 2 missing from index sqlite_autoindex_imps_1; row 3 missing from index sqlite_autoindex_imps_1
image ghcr.io/zgeoff/imp-host:0.29.0@sha256:9b1f6c3e0a4d7f2b8c5e1a6d3f0b9c2e7a4d1f8b5c2e9a6d3f0c7b4e1a8d5f2b
copy: /root/imp-db-backups/pre-x-20261008T120000 (73728 bytes, mode 600)
OUT
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","bash -s -- pre-x"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_answers_a_stopped_imp_host_with_dockers_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_COPY_FAIL=imp-host-stopped ssh -o BatchMode=yes root@geoffcloud "bash -s -- pre-x" \
    < /dev/null > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error response from daemon: No such container: imp-host'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","bash -s -- pre-x"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_a_call_without_batch_mode() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh root@geoffcloud "bash -s -- pre-x" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: root@geoffcloud bash -s -- pre-x'
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","bash -s -- pre-x"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_another_host() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes root@other "bash -s -- pre-x" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes root@other bash -s -- pre-x'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@other","bash -s -- pre-x"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_another_command() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes root@geoffcloud systemctl stop imp-host > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes root@geoffcloud systemctl stop imp-host'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","stop","imp-host"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_a_label_with_another_character() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    ssh -o BatchMode=yes root@geoffcloud "bash -s -- ../x" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes root@geoffcloud bash -s -- ../x'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","bash -s -- ../x"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_hands_a_loopback_call_to_the_real_ssh_which_refuses_a_dead_port_with_exit_255() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "bash -s -- x" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","bash -s -- x"]'
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
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.2:1 "bash -s -- x" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes ssh://root@127.0.0.2:1 bash -s -- x'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.2:1","bash -s -- x"]'
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
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false "bash -s -- x" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false bash -s -- x'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","-oProxyCommand=false","bash -s -- x"]'
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
  PATH="$tree/fake:$PATH" create_stub_impd_db_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"

  env -i PATH="$tree/bin:$tree/fake:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "bash -s -- x" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","bash -s -- x"]'
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
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

run_cases
