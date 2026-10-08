#!/usr/bin/env bash
# Test for create-stub-clock.sh: the fake clock starts at 0 and moves only when the fake
# pause runs, one second per pause, and the pause records each argument, also when it runs
# as the sleep command on PATH. Each command runs under `env -i` with PATH, HOME and TMPDIR
# set, HOME and TMPDIR inside the case tree.
#
#   bash scripts/test-lib/test-create-stub-clock.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-missing.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-clock.sh"

it_reads_0_before_any_pause() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/clock" > "$tree/out"

  diff - "$tree/out" <<< 0
  assert_missing "$tree/pauses" "the clock recorded a pause"
}

it_advances_one_second_for_each_pause_and_records_its_argument() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/sleep" 0.05
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/sleep" 2
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/clock" > "$tree/out"

  diff - "$tree/out" <<< 2
  diff - "$tree/pauses" << 'PAUSES'
0.05
2
PAUSES
}

it_keeps_the_time_still_between_reads() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/sleep" 0.05

  { env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/clock"; env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/clock"; } > "$tree/out"

  diff - "$tree/out" << 'READS'
1
1
READS
}

it_answers_as_the_sleep_command_on_PATH() {
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" sleep 0.05
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" "$tree/clock" > "$tree/out"

  diff - "$tree/out" <<< 1
  diff - "$tree/pauses" <<< 0.05
}

# Runtime every case needs: the clock and pause in <tree>, and the HOME and TMPDIR they run
# with.
setup_test() {
  local tree="$1"
  mkdir "$tree/home" "$tree/tmp"
  create_stub_clock "$tree"
}

run_cases
