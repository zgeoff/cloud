#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-timeout.sh: the timeout stand-in runs the command after the duration and
# passes its exit code back, logs its argv only when a case names a log, exits 124 or 137 without
# running the command when a case expires it, as coreutils' timeout does for a command its TERM or
# its KILL ends, and fails closed on a call without a duration. Those two cases also pin each code
# against the real timeout.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-timeout.sh'
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

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_timeout "$tree/bin"
}

@test "it runs the command and passes its exit code back" {
  setup_test "$tree"

  run -3 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TIMEOUT_LOG="$tree/calls" \
    timeout -k 5 20 bash -c 'echo ran; exit 3'

  assert_output 'ran'
  refute_stderr
  diff - "$tree/calls" <<< '["timeout","-k","5","20","bash","-c","echo ran; exit 3"]'
}

@test "it logs nothing when no log is named" {
  setup_test "$tree"

  run -0 in_dir "$tree" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    timeout 20 true

  refute_output
  diff - <(ls -A "$tree") << 'EOF'
bin
home
tmp
EOF
}

@test "it exits 124 without running the command when expired as the real timeout does" {
  setup_test "$tree"

  run -124 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TIMEOUT_LOG="$tree/calls" \
    STUB_TIMEOUT_EXPIRE=124 timeout 20 bash -c "touch '$tree/ran'"

  refute_output
  refute_stderr
  refute [ -e "$tree/ran" ]
  run -124 /usr/bin/timeout 0.1 sleep 5
}

@test "it exits 137 without running the command when expired past the kill as the real timeout does" {
  setup_test "$tree"

  run -137 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TIMEOUT_EXPIRE=137 timeout -k 5 20 bash -c "touch '$tree/ran'"

  refute_output
  refute_stderr
  refute [ -e "$tree/ran" ]
  run -137 /usr/bin/timeout -k 0.2 0.1 bash -c "trap '' TERM; exec sleep 5"
}

@test "it fails closed with exit 97 on a call without a duration" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    timeout --signal=KILL 20 true

  refute_output
  assert_stderr 'unexpected: --signal=KILL 20 true'
}
