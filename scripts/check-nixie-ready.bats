#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for check-nixie-ready.sh: it passes once nixie health reports every readiness and
# dependency part ready, pausing 10 s after each try that is not, ends a try that hangs after 20 s,
# and after 30 tries fails naming each part that is not ready with nixie's reason, or the last error when no report
# came back. ssh is the NixOS host stand-in (create-stub-nixos-ssh.sh), which answers the kubectl
# exec with the reports a case names, and the pause is the fake clock's (create-stub-clock.sh),
# first on PATH as sleep, so a case counts pauses instead of waiting them out. Each case runs the script under `env -i` and
# compares its whole stdout, stderr, ssh call log and pauses. timeout is a stand-in too
# (create-stub-timeout.sh), so a case ends a hung try without waiting out the 20 s limit.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-nixos-ssh.sh'
  load 'src/test-utils/shell/create-stub-clock.sh'
  load 'src/test-utils/shell/create-stub-remote-tools.sh'
  load 'src/test-utils/shell/create-stub-timeout.sh'
  load 'src/test-utils/shell/require-remote-tool-stubs.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/check-nixie-ready.sh"
  exec_call='["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]'
  ready='{"status":"ready","parts":{"store":{"isReady":true},"imp_host":{"isReady":true},"model":{"isReady":true}}}'
  # nixie's report while its turns keep failing: an advisory part, with the status ready
  ready_failing_turns='{"status":"ready","parts":{"store":{"isReady":true},"imp_host":{"isReady":true},"model":{"isReady":true}},"advisory":{"conversation_turns":{"isReady":false,"reason":"the last 3 turns failed"}}}'
  unready='{"status":"unready","parts":{"store":{"isReady":true},"imp_host":{"isReady":false,"reason":"impd 4.0.0 refuses imp client 3.2.1"},"model":{"isReady":false,"reason":"the check took longer than 2000 ms"}}}'
  # nixie's reports with dependency parts: degraded while impd fails, which answers 200, and ready
  degraded='{"status":"degraded","parts":{"store":{"isReady":true}},"dependencies":{"imp_host":{"isReady":false,"reason":"impd 4.0.0 refuses imp client 3.2.1"},"disk":{"isReady":true}}}'
  ready_dependencies='{"status":"ready","parts":{"store":{"isReady":true}},"dependencies":{"imp_host":{"isReady":true},"disk":{"isReady":true}}}'
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# setup_test <tree>: the ssh stand-in and its guard, the timeout stand-in, and the fake clock
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/clock" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_nixos_ssh "$tree/bin"
  create_stub_timeout "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
  create_stub_clock "$tree/clock"
}

# repeat_line <n> <line>: prints <line> n times
repeat_line() {
  for _ in $(seq 1 "$1"); do printf '%s\n' "$2"; done
}

@test "it passes at once when every part is ready" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_NIXIE_REPORTS="$ready" bash "$script" root@geoffcloud

  assert_output '== nixie ready: store, imp_host, model'
  refute_stderr

  run -0 diff - "$tree/calls" <<< "$exec_call"
  refute [ -e "$tree/clock/pauses" ]
}

@test "it passes naming each advisory part that is not ready" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_NIXIE_REPORTS="$ready_failing_turns" bash "$script" root@geoffcloud

  assert_output - << 'EOF'
== nixie ready: store, imp_host, model
== nixie advisory not ready: conversation_turns: the last 3 turns failed
EOF
  refute_stderr

  run -0 diff - "$tree/calls" <<< "$exec_call"
  refute [ -e "$tree/clock/pauses" ]
}

@test "it pauses 10 seconds after each try that is not ready" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_NIXIE_REPORTS="$unready"$'\n'"$unready"$'\n'"$ready" bash "$script" root@geoffcloud

  assert_output '== nixie ready: store, imp_host, model'
  refute_stderr

  run -0 diff - "$tree/calls" <<< "$(repeat_line 3 "$exec_call")"
  run -0 diff - "$tree/clock/pauses" <<< "$(repeat_line 2 10)"
}

@test "it fails after 30 tries naming each part that is not ready" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_NIXIE_REPORTS="$unready" bash "$script" root@geoffcloud

  refute_output
  assert_stderr 'nixie is not ready after 30 tries: imp_host: impd 4.0.0 refuses imp client 3.2.1; model: the check took longer than 2000 ms'

  run -0 diff - "$tree/calls" <<< "$(repeat_line 30 "$exec_call")"
  run -0 diff - "$tree/clock/pauses" <<< "$(repeat_line 29 10)"
}

@test "it fails on an unready status even when every part reads ready" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_NIXIE_REPORTS='{"status":"unready","parts":{"store":{"isReady":true}}}' bash "$script" root@geoffcloud

  refute_output
  assert_stderr 'nixie is not ready after 30 tries: status "unready"'
}

@test "it passes naming the dependency parts once a degraded nixie reports ready" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_NIXIE_REPORTS="$degraded"$'\n'"$ready_dependencies" bash "$script" root@geoffcloud

  assert_output '== nixie ready: store, imp_host, disk'
  refute_stderr

  run -0 diff - "$tree/calls" <<< "$(repeat_line 2 "$exec_call")"
  run -0 diff - "$tree/clock/pauses" <<< '10'
}

@test "it fails after 30 tries naming each dependency part that is not ready" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_NIXIE_REPORTS="$degraded" bash "$script" root@geoffcloud

  refute_output
  assert_stderr 'nixie is not ready after 30 tries: imp_host: impd 4.0.0 refuses imp client 3.2.1'

  run -0 diff - "$tree/calls" <<< "$(repeat_line 30 "$exec_call")"
  run -0 diff - "$tree/clock/pauses" <<< "$(repeat_line 29 10)"
}

@test "it fails with the last error when no report comes back" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bash "$script" root@geoffcloud

  refute_output
  assert_stderr 'nixie is not ready after 30 tries: no report from nixie-0: Error from server (NotFound): pods "nixie-0" not found'

  run -0 diff - "$tree/calls" <<< "$(repeat_line 30 "$exec_call")"
  run -0 diff - "$tree/clock/pauses" <<< "$(repeat_line 29 10)"
}

@test "it ends each try after 20 seconds and fails naming the hang" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TIMEOUT_LOG="$tree/timeouts" STUB_TIMEOUT_EXPIRE=124 STUB_NIXIE_REPORTS="$ready" \
    bash "$script" root@geoffcloud

  refute_output
  assert_stderr 'nixie is not ready after 30 tries: no report from nixie-0: the try took longer than 20 s'

  run -0 diff /dev/null "$tree/calls"
  run -0 diff - "$tree/timeouts" <<< "$(repeat_line 30 "$(jq -c '["timeout","-k","5","20"] + .' <<< "$exec_call")")"
  run -0 diff - "$tree/clock/pauses" <<< "$(repeat_line 29 10)"
}

@test "it rejects a ready report from a try that then hangs" {
  setup_test "$tree"
  # a timeout that runs the command, so its report prints, then ends the try as the TERM at 20 s does
  cat > "$tree/bin/timeout" << 'STUB'
#!/usr/bin/env bash
shift 3
"$@" || true
exit 124
STUB
  chmod +x "$tree/bin/timeout"

  run -1 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_NIXIE_REPORTS="$ready" bash "$script" root@geoffcloud

  refute_output
  assert_stderr 'nixie is not ready after 30 tries: no report from nixie-0: the try took longer than 20 s'

  run -0 diff - "$tree/calls" <<< "$(repeat_line 30 "$exec_call")"
}

@test "it counts a try that the kill after the deadline ends as a hang" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TIMEOUT_LOG="$tree/timeouts" STUB_TIMEOUT_EXPIRE=137 STUB_NIXIE_REPORTS="$ready" \
    bash "$script" root@geoffcloud

  refute_output
  assert_stderr 'nixie is not ready after 30 tries: no report from nixie-0: the try took longer than 20 s'

  run -0 diff /dev/null "$tree/calls"
  run -0 diff - "$tree/timeouts" <<< "$(repeat_line 30 "$(jq -c '["timeout","-k","5","20"] + .' <<< "$exec_call")")"
  run -0 diff - "$tree/clock/pauses" <<< "$(repeat_line 29 10)"
}

@test "it prints its usage without a host" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bash "$script"

  refute_output
  assert_stderr 'usage: check-nixie-ready.sh <host>'

  run -0 diff /dev/null "$tree/calls"
}
