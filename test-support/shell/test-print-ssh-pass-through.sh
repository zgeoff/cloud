#!/usr/bin/env bash
# Test for print-ssh-pass-through.sh: the lines it prints leave a call to the stand-in's own
# answers without STUB_SSH_PASS, and with it hand a loopback call to the real ssh on the system
# path and refuse every other call with exit 97. Each case runs a stand-in made of those lines and
# one answer of its own. The pass-through cases pin what the ssh stand-ins assume about the real
# ssh: a refused connection exits 255 with "ssh: connect to host … port …: Connection refused" and
# the CR LF that its log ends a line with on stderr, as OpenSSH 9.6p1 (CI's ubuntu-24.04 runner
# image 20261004) and 10.5p1 print it.
#
#   bash test-support/shell/test-print-ssh-pass-through.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/print-ssh-pass-through.sh"

it_leaves_the_call_to_the_stand_ins_own_answers_without_STUB_SSH_PASS() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "true" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'own answer: -o BatchMode=yes ssh://root@127.0.0.1:1 true'
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_hands_a_loopback_call_to_the_real_ssh_which_refuses_a_dead_port_with_exit_255() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_SSH_PASS=1 \
    ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "true" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  assert_status 255 "$status"
}

# 127.0.0.2 is loopback too, so a broken guard would only reach a dead local port, never a
# real host; the guard admits 127.0.0.1 alone.
it_never_hands_a_call_to_another_destination_to_the_real_ssh() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_SSH_PASS=1 \
    ssh -o BatchMode=yes ssh://root@127.0.0.2:1 "true" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes ssh://root@127.0.0.2:1 true'
  assert_status 97 "$status"
}

# OpenSSH reads an option even after the destination, so the guard refuses one there before it
# calls the real ssh.
it_never_hands_a_call_with_an_option_after_the_destination_to_the_real_ssh() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_SSH_PASS=1 \
    ssh -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false "true" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false true'
  assert_status 97 "$status"
}

it_hands_a_call_to_the_system_ssh_not_one_on_the_callers_PATH() {
  local status=0
  create_case_tree
  mkdir "$tree/fake"
  printf '#!/usr/bin/env bash\necho fake ssh\n' > "$tree/fake/ssh"
  chmod +x "$tree/fake/ssh"
  PATH="$tree/fake:$PATH" setup_test "$tree"

  env -i PATH="$tree/bin:$tree/fake:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_SSH_PASS=1 \
    ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "true" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  assert_status 255 "$status"
}

# Runtime every case needs: <tree>/bin/ssh, a stand-in made of the printed lines and one answer
# of its own, which prints its argv, and the HOME and TMPDIR it runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  {
    echo '#!/usr/bin/env bash'
    print_ssh_pass_through
    # shellcheck disable=SC2016 # the stand-in expands its own argv
    echo 'echo "own answer: $*"'
  } > "$tree/bin/ssh"
  chmod +x "$tree/bin/ssh"
}

run_cases
