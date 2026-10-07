#!/usr/bin/env bash
# Test for wait-for.sh: wait_for polls a command until it succeeds, and fails with a
# named message once its deadline passes. The cases step the fake clock from
# create-stub-clock.sh, so a deadline costs no real time; the last case checks the
# defaults, bash's SECONDS and sleep, with a sleep function that steps SECONDS.
#
#   bash scripts/test-lib/test-wait-for.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-clock.sh"

it_returns_once_the_command_succeeds_on_a_later_poll() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  create_stub_clock "$tree"
  # shellcheck disable=SC2016 # expanded by the poll script
  printf '#!/usr/bin/env bash\necho poll >> "%s/polls"\n[ "$(wc -l < "%s/polls")" -ge 3 ]\n' "$tree" "$tree" > "$tree/third-poll"
  chmod +x "$tree/third-poll"

  WAIT_FOR_CLOCK="$tree/clock" WAIT_FOR_SLEEP="$tree/sleep" \
    wait_for 5 "the third poll" "$tree/third-poll" > "$tree/out" 2>&1 || status=$?

  diff /dev/null "$tree/out"
  wc -l < "$tree/polls" > "$tree/poll-count"
  diff - "$tree/poll-count" <<< 3
  diff - "$tree/pauses" << 'PAUSES'
0.05
0.05
PAUSES
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_returns_without_polling_again_when_the_command_succeeds_at_once() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  create_stub_clock "$tree"
  printf '#!/usr/bin/env bash\necho poll >> "%s/polls"\n' "$tree" > "$tree/first-poll"
  chmod +x "$tree/first-poll"

  WAIT_FOR_CLOCK="$tree/clock" WAIT_FOR_SLEEP="$tree/sleep" \
    wait_for 5 "the first poll" "$tree/first-poll" > "$tree/out" 2>&1 || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/polls" <<< poll
  [ ! -e "$tree/pauses" ] || { echo "wait_for paused after a poll that succeeded" >&2; exit 1; }
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# The deadline is 3 seconds after the clock's 0. Each failed poll before it pauses, and the
# pause moves the clock one second, so the fourth poll fails at second 3 and ends the wait.
it_fails_with_a_named_message_once_the_deadline_passes() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  create_stub_clock "$tree"
  printf '#!/usr/bin/env bash\necho poll >> "%s/polls"\nexit 1\n' "$tree" > "$tree/never"
  chmod +x "$tree/never"

  WAIT_FOR_CLOCK="$tree/clock" WAIT_FOR_SLEEP="$tree/sleep" \
    wait_for 3 "a condition that never holds" "$tree/never" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'timed out after 3s waiting for a condition that never holds'
  wc -l < "$tree/polls" > "$tree/poll-count"
  diff - "$tree/poll-count" <<< 4
  diff - "$tree/pauses" << 'PAUSES'
0.05
0.05
0.05
PAUSES
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_passes_the_command_arguments_through_unchanged() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  create_stub_clock "$tree"
  touch "$tree/a file with spaces"

  WAIT_FOR_CLOCK="$tree/clock" WAIT_FOR_SLEEP="$tree/sleep" \
    wait_for 5 "the file" test -f "$tree/a file with spaces" > "$tree/out" 2>&1 || status=$?

  diff /dev/null "$tree/out"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# With neither WAIT_FOR_CLOCK nor WAIT_FOR_SLEEP set, wait_for reads bash's SECONDS and
# calls sleep by name, so a sleep function in the case shell stands in for the real one:
# it records the pause and moves SECONDS on one second. SECONDS starts at 0 so no real
# second passes during the case, and the deadline falls at the first pause.
it_times_out_on_bashs_seconds_and_sleep_when_neither_is_set() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  # shellcheck disable=SC2329 # wait_for calls it by name
  sleep() {
    echo "$1" >> "$tree/pauses"
    SECONDS=$((SECONDS + 1))
  }
  SECONDS=0

  wait_for 1 "a condition that never holds" false > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'timed out after 1s waiting for a condition that never holds'
  diff - "$tree/pauses" <<< 0.05
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

unset WAIT_FOR_CLOCK WAIT_FOR_SLEEP
run_cases
