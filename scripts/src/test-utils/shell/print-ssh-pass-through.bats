#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for print-ssh-pass-through.sh: the lines it prints leave a call to the stand-in's own
# answers without STUB_SSH_PASS, and with it hand a loopback call to the real ssh on the system
# path and refuse every other call with exit 97. Each case runs a stand-in made of those lines and
# one answer of its own. The pass-through cases pin what the ssh stand-ins assume about the real
# ssh: a refused connection exits 255 with "ssh: connect to host … port …: Connection refused" and
# the CR LF that its log ends a line with on stderr, as OpenSSH 9.6p1 (CI's ubuntu-24.04 runner
# image 20261004) and 10.5p1 print it.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'print-ssh-pass-through.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
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

@test "it leaves the call to the stand ins own answers without STUB SSH PASS" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "true"

  assert_output 'own answer: -o BatchMode=yes ssh://root@127.0.0.1:1 true'
  refute_stderr
}

@test "it hands a loopback call to the real ssh which refuses a dead port with exit 255" {
  setup_test "$tree"

  run -255 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_SSH_PASS=1 \
    ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "true"

  refute_output
  assert_stderr $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
}

# 127.0.0.2 is loopback too, so a broken guard would only reach a dead local port, never a
# real host; the guard admits 127.0.0.1 alone.
@test "it never hands a call to another destination to the real ssh" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_SSH_PASS=1 \
    ssh -o BatchMode=yes ssh://root@127.0.0.2:1 "true"

  refute_output
  assert_stderr 'unexpected: -o BatchMode=yes ssh://root@127.0.0.2:1 true'
}

# OpenSSH reads an option even after the destination, so the guard refuses one there before it
# calls the real ssh.
@test "it never hands a call with an option after the destination to the real ssh" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_SSH_PASS=1 \
    ssh -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false "true"

  refute_output
  assert_stderr 'unexpected: -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false true'
}

@test "it hands a call to the system ssh not one on the callers PATH" {
  mkdir "$tree/fake"
  printf '#!/usr/bin/env bash\necho fake ssh\n' > "$tree/fake/ssh"
  chmod +x "$tree/fake/ssh"
  PATH="$tree/fake:$PATH" setup_test "$tree"

  run -255 --separate-stderr env -i PATH="$tree/bin:$tree/fake:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_SSH_PASS=1 \
    ssh -o BatchMode=yes ssh://root@127.0.0.1:1 "true"

  refute_output
  assert_stderr $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
}
