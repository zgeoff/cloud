#!/usr/bin/env bash
# Test for create-stub-racing-restic.sh: the restic stand-in runs its race script once, right
# before the first `restore` call, then hands that call on (or, when the script fails, passes its
# status through and runs nothing), and hands every other call to the real restic unchanged. echo
# and false stand in for the real restic, so the cases read what reached it.
#
#   bash test-support/shell/test-create-stub-racing-restic.sh
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # each race script expands when the stand-in runs it
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-missing.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-racing-restic.sh"

it_runs_the_race_script_once_before_the_first_restore_then_hands_each_call_on() {
  local status=0
  create_case_tree
  setup_test "$tree" /bin/echo
  echo 'echo raced >> "$(dirname "$0")/races"' > "$tree/race.sh"

  {
    run_stub "$tree" restore latest --tag set-2 --target /tmp/copy
    run_stub "$tree" restore latest --tag set-3 --target /tmp/copy
  } > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
restore latest --tag set-2 --target /tmp/copy
restore latest --tag set-3 --target /tmp/copy
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/races" <<< raced
  diff - "$tree/state/log" <<< '["restic-raced"]'
  assert_status 0 "$status"
}

it_passes_a_failed_race_scripts_status_through_and_runs_no_restic() {
  local status=0
  create_case_tree
  setup_test "$tree" /bin/echo
  echo 'echo "race failed" >&2; exit 3' > "$tree/race.sh"

  run_stub "$tree" restore latest --target /tmp/copy > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'race failed'
  assert_missing "$tree/state/log" "the stand-in logged a race"
  assert_status 3 "$status"
}

it_hands_every_other_call_to_the_real_restic_unchanged() {
  local status=0
  create_case_tree
  setup_test "$tree" /bin/echo
  echo 'echo raced >> "$(dirname "$0")/races"' > "$tree/race.sh"

  run_stub "$tree" snapshots --json > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'snapshots --json'
  diff /dev/null "$tree/err"
  assert_missing "$tree/races" "the stand-in ran the race script"
  assert_missing "$tree/state/log" "the stand-in logged a race"
  assert_status 0 "$status"
}

it_passes_the_real_restics_exit_code_through() {
  local status=0
  create_case_tree
  setup_test "$tree" /bin/false
  : > "$tree/race.sh"

  run_stub "$tree" restore latest --target /tmp/copy > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  assert_status 1 "$status"
}

# Runtime every case needs: the stand-in in <tree>/bin, handing calls to <real restic>, with its
# race script at <tree>/race.sh and its state folder at <tree>/state.
setup_test() {
  local tree="$1" real_restic="$2"
  mkdir "$tree/bin" "$tree/state"
  create_stub_racing_restic "$tree/bin" "$real_restic" "$tree/race.sh" "$tree/state"
}

# run_stub <tree> <arg>...: the stand-in, run as the restore script runs restic
run_stub() {
  local tree="$1"
  shift
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" TMPDIR="$tree" restic "$@"
}

run_cases
