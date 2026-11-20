#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-scripted-command.sh: the stand-in answers each call in turn from its
# script of answers, with that call's stdout, stderr and status, logs every call with its working
# directory, logs the environment variables it is told to, takes its log and answers from paths it
# was given in place of the environment's, and fails closed with exit 97 on a call the script has
# no answer for.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-scripted-command.sh'
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
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/work" "$tree/answers"
  create_stub_scripted_command "$tree/bin" pulumi
}

@test "it answers each call in turn with its own output and status" {
  setup_test "$tree"
  local preview=(in_dir "$tree/work" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp"
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" pulumi preview --refresh)
  printf 'first out\n' > "$tree/answers/1.out"
  printf 'first err\n' > "$tree/answers/1.err"
  echo 7 > "$tree/answers/1.status"
  printf 'second out\n' > "$tree/answers/2.out"

  run -7 --separate-stderr "${preview[@]}"
  assert_output 'first out'
  assert_stderr 'first err'
  run -0 --separate-stderr "${preview[@]}"
  assert_output 'second out'
  refute_stderr
  diff - "$tree/calls" << EOF
{"cwd":"$tree/work","argv":["pulumi","preview","--refresh"]}
{"cwd":"$tree/work","argv":["pulumi","preview","--refresh"]}
EOF
}

@test "it fails closed with exit 97 on a call with no answer" {
  setup_test "$tree"

  run -97 --separate-stderr in_dir "$tree/work" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" pulumi up --yes

  refute_output
  assert_stderr 'unexpected: call 1: up --yes'
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/work\",\"argv\":[\"pulumi\",\"up\",\"--yes\"]}"
}

@test "it logs the named variables that the call s environment sets" {
  setup_test "$tree"
  printf 'done\n' > "$tree/answers/1.out"

  run -0 --separate-stderr in_dir "$tree/work" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" STUB_LOG_ENV='API_TOKEN EMPTY_VALUE WEBHOOK_URL' \
    API_TOKEN='tok en=1' EMPTY_VALUE= pulumi refresh

  assert_output 'done'
  refute_stderr
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/work\",\"argv\":[\"pulumi\",\"refresh\"],\"env\":{\"API_TOKEN\":\"tok en=1\",\"EMPTY_VALUE\":\"\"}}"
}

@test "it logs to and answers from the paths it was given in place of the environment s" {
  setup_test "$tree"
  mkdir "$tree/curl-answers"
  create_stub_scripted_command "$tree/bin" curl "$tree/curl-calls" "$tree/curl-answers"
  printf 'curl out\n' > "$tree/curl-answers/1.out"

  run -0 --separate-stderr in_dir "$tree/work" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" curl -fsS https://api.github.test

  assert_output 'curl out'
  refute_stderr
  diff - "$tree/curl-calls" <<< "{\"cwd\":\"$tree/work\",\"argv\":[\"curl\",\"-fsS\",\"https://api.github.test\"]}"
  refute [ -e "$tree/calls" ]
  refute [ -e "$tree/answers/count" ]
}
