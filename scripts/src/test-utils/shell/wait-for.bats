#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for wait-for.sh: wait_for polls a command until it succeeds, and fails with a
# named message once its deadline passes. The cases step the fake clock from
# create-stub-clock.sh, so a deadline costs no real time. Two cases cover the defaults
# without waiting: one reaches a deadline on bash's SECONDS by advancing it from the poll,
# and one finds create_stub_clock's pause as the sleep command on PATH.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'wait-for.sh'
  load 'create-stub-clock.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  unset WAIT_FOR_CLOCK WAIT_FOR_SLEEP
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

@test "it returns once the command succeeds on a later poll" {
  create_stub_clock "$tree"
  # shellcheck disable=SC2016 # expanded by the poll script
  printf '#!/usr/bin/env bash\necho poll >> "%s/polls"\n[ "$(wc -l < "%s/polls")" -ge 3 ]\n' "$tree" "$tree" > "$tree/third-poll"
  chmod +x "$tree/third-poll"

  WAIT_FOR_CLOCK="$tree/clock" WAIT_FOR_SLEEP="$tree/sleep" \
    run -0 wait_for 5 "the third poll" "$tree/third-poll"

  refute_output
  wc -l < "$tree/polls" > "$tree/poll-count"
  diff - "$tree/poll-count" <<< 3
  diff - "$tree/pauses" << 'PAUSES'
0.05
0.05
PAUSES
}

@test "it returns without polling again when the command succeeds at once" {
  create_stub_clock "$tree"
  printf '#!/usr/bin/env bash\necho poll >> "%s/polls"\n' "$tree" > "$tree/first-poll"
  chmod +x "$tree/first-poll"

  WAIT_FOR_CLOCK="$tree/clock" WAIT_FOR_SLEEP="$tree/sleep" \
    run -0 wait_for 5 "the first poll" "$tree/first-poll"

  refute_output
  diff - "$tree/polls" <<< poll
  refute [ -e "$tree/pauses" ]
  refute [ -L "$tree/pauses" ]
}

# The deadline is 3 seconds after the clock's 0. Each failed poll before it pauses, and the
# pause moves the clock one second, so the fourth poll fails at second 3 and ends the wait.
@test "it fails with a named message once the deadline passes" {
  create_stub_clock "$tree"
  printf '#!/usr/bin/env bash\necho poll >> "%s/polls"\nexit 1\n' "$tree" > "$tree/never"
  chmod +x "$tree/never"

  WAIT_FOR_CLOCK="$tree/clock" WAIT_FOR_SLEEP="$tree/sleep" \
    run -1 --separate-stderr wait_for 3 "a condition that never holds" "$tree/never"

  refute_output
  assert_stderr 'timed out after 3s waiting for a condition that never holds'
  wc -l < "$tree/polls" > "$tree/poll-count"
  diff - "$tree/poll-count" <<< 4
  diff - "$tree/pauses" << 'PAUSES'
0.05
0.05
0.05
PAUSES
}

@test "it passes the command arguments through unchanged" {
  create_stub_clock "$tree"
  touch "$tree/a file with spaces"

  WAIT_FOR_CLOCK="$tree/clock" WAIT_FOR_SLEEP="$tree/sleep" \
    run -0 wait_for 5 "the file" test -f "$tree/a file with spaces"

  refute_output
}

# With no WAIT_FOR_CLOCK, wait_for reads bash's SECONDS. The poll runs in wait_for's own
# shell through eval, so it moves SECONDS on by 100 each time: the deadline 250 seconds
# after the start passes at the third poll, however many real seconds tick meanwhile. The
# tenth poll stops a wait that never reads SECONDS, so a broken default fails the case
# instead of hanging it.
@test "it times out on bashs SECONDS when no clock is set" {
  create_stub_clock "$tree"

  # shellcheck disable=SC2016 # expanded by eval inside wait_for
  WAIT_FOR_SLEEP="$tree/sleep" run -1 --separate-stderr wait_for 250 "a condition that never holds" \
    eval 'echo poll >> "$tree/polls"; SECONDS=$((SECONDS + 100)); [ "$(wc -l < "$tree/polls")" -ge 10 ]'

  refute_output
  assert_stderr 'timed out after 250s waiting for a condition that never holds'
  wc -l < "$tree/polls" > "$tree/poll-count"
  diff - "$tree/poll-count" <<< 3
  diff - "$tree/pauses" << 'PAUSES'
0.05
0.05
PAUSES
}

# With no WAIT_FOR_SLEEP, wait_for pauses with the sleep command it finds on PATH; here
# that is create_stub_clock's pause, which records each pause and steps the fake clock.
@test "it pauses with the sleep command on PATH when no pause is set" {
  create_stub_clock "$tree"
  # shellcheck disable=SC2016 # expanded by the poll script
  printf '#!/usr/bin/env bash\necho poll >> "%s/polls"\n[ "$(wc -l < "%s/polls")" -ge 3 ]\n' "$tree" "$tree" > "$tree/third-poll"
  chmod +x "$tree/third-poll"

  PATH="$tree:$PATH" WAIT_FOR_CLOCK="$tree/clock" \
    run -0 wait_for 5 "the third poll" "$tree/third-poll"

  refute_output
  wc -l < "$tree/polls" > "$tree/poll-count"
  diff - "$tree/poll-count" <<< 3
  diff - "$tree/pauses" << 'PAUSES'
0.05
0.05
PAUSES
}
