#!/usr/bin/env bash
# Test for wait-for.sh: wait_for polls a command until it succeeds, and fails with a
# named message once its deadline passes. The cases step the fake clock from
# create-stub-clock.sh, so a deadline costs no real time. Two cases cover the defaults
# without waiting: one reaches a deadline on bash's SECONDS by advancing it from the poll,
# and one finds create_stub_clock's pause as the sleep command on PATH.
#
#   bash scripts/test-lib/test-wait-for.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-missing.sh"
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
  assert_missing "$tree/pauses" "wait_for paused after a poll that succeeded"
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

# With no WAIT_FOR_CLOCK, wait_for reads bash's SECONDS. The poll runs in wait_for's own
# shell through eval, so it moves SECONDS on by 100 each time: the deadline 250 seconds
# after the start passes at the third poll, however many real seconds tick meanwhile. The
# tenth poll stops a wait that never reads SECONDS, so a broken default fails the case
# instead of hanging it.
it_times_out_on_bashs_SECONDS_when_no_clock_is_set() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  create_stub_clock "$tree"

  # shellcheck disable=SC2016 # expanded by eval inside wait_for
  WAIT_FOR_SLEEP="$tree/sleep" wait_for 250 "a condition that never holds" \
    eval 'echo poll >> "$tree/polls"; SECONDS=$((SECONDS + 100)); [ "$(wc -l < "$tree/polls")" -ge 10 ]' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'timed out after 250s waiting for a condition that never holds'
  wc -l < "$tree/polls" > "$tree/poll-count"
  diff - "$tree/poll-count" <<< 3
  diff - "$tree/pauses" << 'PAUSES'
0.05
0.05
PAUSES
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# With no WAIT_FOR_SLEEP, wait_for pauses with the sleep command it finds on PATH; here
# that is create_stub_clock's pause, which records each pause and steps the fake clock.
it_pauses_with_the_sleep_command_on_PATH_when_no_pause_is_set() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  create_stub_clock "$tree"
  # shellcheck disable=SC2016 # expanded by the poll script
  printf '#!/usr/bin/env bash\necho poll >> "%s/polls"\n[ "$(wc -l < "%s/polls")" -ge 3 ]\n' "$tree" "$tree" > "$tree/third-poll"
  chmod +x "$tree/third-poll"

  PATH="$tree:$PATH" WAIT_FOR_CLOCK="$tree/clock" \
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

unset WAIT_FOR_CLOCK WAIT_FOR_SLEEP
run_cases
