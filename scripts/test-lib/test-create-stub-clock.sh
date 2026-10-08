#!/usr/bin/env bash
# Test for create-stub-clock.sh: the fake clock starts at 0 and moves only when the fake
# pause runs, one second per pause, and the pause records each argument, also when it runs
# as the sleep command on PATH.
#
#   bash scripts/test-lib/test-create-stub-clock.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-clock.sh"

it_reads_0_before_any_pause() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  create_stub_clock "$tree"

  "$tree/clock" > "$tree/out"

  diff - "$tree/out" <<< 0
  [ ! -e "$tree/pauses" ] || { echo "the clock recorded a pause" >&2; exit 1; }
}

it_advances_one_second_for_each_pause_and_records_its_argument() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  create_stub_clock "$tree"

  "$tree/sleep" 0.05
  "$tree/sleep" 2
  "$tree/clock" > "$tree/out"

  diff - "$tree/out" <<< 2
  diff - "$tree/pauses" << 'PAUSES'
0.05
2
PAUSES
}

it_keeps_the_time_still_between_reads() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  create_stub_clock "$tree"
  "$tree/sleep" 0.05

  { "$tree/clock"; "$tree/clock"; } > "$tree/out"

  diff - "$tree/out" << 'READS'
1
1
READS
}

it_answers_as_the_sleep_command_on_PATH() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  create_stub_clock "$tree"

  PATH="$tree:$PATH" sleep 0.05
  "$tree/clock" > "$tree/out"

  diff - "$tree/out" <<< 1
  diff - "$tree/pauses" <<< 0.05
}

run_cases
