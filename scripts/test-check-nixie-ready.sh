#!/usr/bin/env bash
# Test for check-nixie-ready.sh: it passes once nixie health reports every part ready,
# pausing 10 s after each try that is not, ends a try that hangs after 20 s, and after 30 tries
# fails naming each part that is not ready with nixie's reason, or the last error when no report
# came back. ssh is the NixOS host stand-in (create-stub-nixos-ssh.sh), which answers the kubectl
# exec with the reports a case names, and the pause is the fake clock's (create-stub-clock.sh),
# first on PATH as sleep, so a case counts pauses instead of waiting them out. Each case runs the script under `env -i` and
# compares its whole stdout, stderr, ssh call log and pauses. timeout is a stand-in too
# (create-stub-timeout.sh), so a case ends a hung try without waiting out the 20 s limit.
#
#   bash scripts/test-check-nixie-ready.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-nixos-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-clock.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-timeout.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/require-remote-tool-stubs.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-nixie-ready.sh"
exec_call='["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]'
ready='{"status":"ready","parts":{"store":{"isReady":true},"imp_host":{"isReady":true},"model":{"isReady":true}}}'
unready='{"status":"unready","parts":{"store":{"isReady":true},"imp_host":{"isReady":false,"reason":"impd 4.0.0 refuses imp client 3.2.1"},"model":{"isReady":false,"reason":"the check took longer than 2000 ms"}}}'

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

it_passes_at_once_when_every_part_is_ready() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_NIXIE_REPORTS="$ready" bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '== nixie ready: store, imp_host, model'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "$exec_call"
  [ ! -e "$tree/clock/pauses" ] || {
    echo "it paused: $(cat "$tree/clock/pauses")" >&2
    exit 1
  }
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_pauses_10_seconds_after_each_try_that_is_not_ready() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_NIXIE_REPORTS="$unready"$'\n'"$unready"$'\n'"$ready" bash "$script" root@geoffcloud \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '== nixie ready: store, imp_host, model'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "$(repeat_line 3 "$exec_call")"
  diff - "$tree/clock/pauses" <<< "$(repeat_line 2 10)"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_after_30_tries_naming_each_part_that_is_not_ready() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_NIXIE_REPORTS="$unready" bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'nixie is not ready after 30 tries: imp_host: impd 4.0.0 refuses imp client 3.2.1; model: the check took longer than 2000 ms'
  diff - "$tree/calls" <<< "$(repeat_line 30 "$exec_call")"
  diff - "$tree/clock/pauses" <<< "$(repeat_line 29 10)"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_on_an_unready_status_even_when_every_part_reads_ready() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_NIXIE_REPORTS='{"status":"unready","parts":{"store":{"isReady":true}}}' bash "$script" root@geoffcloud \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'nixie is not ready after 30 tries: status "unready"'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_with_the_last_error_when_no_report_comes_back() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'nixie is not ready after 30 tries: no report from nixie-0: Error from server (NotFound): pods "nixie-0" not found'
  diff - "$tree/calls" <<< "$(repeat_line 30 "$exec_call")"
  diff - "$tree/clock/pauses" <<< "$(repeat_line 29 10)"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_ends_each_try_after_20_seconds_and_fails_naming_the_hang() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TIMEOUT_LOG="$tree/timeouts" STUB_TIMEOUT_EXPIRE=124 STUB_NIXIE_REPORTS="$ready" \
    bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'nixie is not ready after 30 tries: no report from nixie-0: the try took longer than 20 s'
  diff /dev/null "$tree/calls"
  diff - "$tree/timeouts" <<< "$(repeat_line 30 "$(jq -c '["timeout","-k","5","20"] + .' <<< "$exec_call")")"
  diff - "$tree/clock/pauses" <<< "$(repeat_line 29 10)"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_counts_a_try_that_the_kill_after_the_deadline_ends_as_a_hang() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TIMEOUT_LOG="$tree/timeouts" STUB_TIMEOUT_EXPIRE=137 STUB_NIXIE_REPORTS="$ready" \
    bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'nixie is not ready after 30 tries: no report from nixie-0: the try took longer than 20 s'
  diff /dev/null "$tree/calls"
  diff - "$tree/timeouts" <<< "$(repeat_line 30 "$(jq -c '["timeout","-k","5","20"] + .' <<< "$exec_call")")"
  diff - "$tree/clock/pauses" <<< "$(repeat_line 29 10)"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_rejects_a_ready_report_from_a_try_that_then_hangs() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  # a timeout that runs the command, so its report prints, then ends the try as the TERM at 20 s does
  cat > "$tree/bin/timeout" << 'STUB'
#!/usr/bin/env bash
shift 3
"$@" || true
exit 124
STUB
  chmod +x "$tree/bin/timeout"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_NIXIE_REPORTS="$ready" bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'nixie is not ready after 30 tries: no report from nixie-0: the try took longer than 20 s'
  diff - "$tree/calls" <<< "$(repeat_line 30 "$exec_call")"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_prints_its_usage_without_a_host() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: check-nixie-ready.sh <host>'
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

run_cases
