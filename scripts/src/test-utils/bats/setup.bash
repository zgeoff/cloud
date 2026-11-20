# shellcheck shell=bash
# The setup every .bats file shares. Load it from both of the file's setup functions:
#
#   setup_file() {
#     load '<relative path to>/scripts/src/test-utils/bats/setup'
#   }
#
#   setup() {
#     load '<relative path to>/scripts/src/test-utils/bats/setup'
#   }
#
# It needs bats 1.5.0 for `run -<status>`, loads bats-support and bats-assert from the libraries
# that scripts/run-bats.sh puts on BATS_LIB_PATH, and gives a test 30 seconds unless its file set
# BATS_TEST_TIMEOUT above its tests. bats reads the timeout before a test's own setup runs, so only
# setup_file can set the default; setup has the libraries.
bats_require_minimum_version 1.5.0
bats_load_library bats-support
bats_load_library bats-assert
export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-30}"

# stop_timeout_watchdog: call it first in every teardown. bats 1.13 leaves the timeout watchdog of a
# failed test running until its timeout passes, and bats waits for it, so one failed case would hold
# up the end of the run for BATS_TEST_TIMEOUT seconds. bats keeps the watchdog's pid in a variable
# that a failed test no longer sees, so this finds the watchdog as the child of the test's shell
# that waits on `sleep <timeout>`, and stops it.
stop_timeout_watchdog() {
  local watchdog sleeper
  for watchdog in $(ps -o pid= --ppid $$); do
    for sleeper in $(ps -o pid= --ppid "$watchdog"); do
      if [ "$(ps -o args= -p "$sleeper")" = "sleep ${BATS_TEST_TIMEOUT:-}" ]; then
        kill "$watchdog" &> /dev/null || true
      fi
    done
  done
}
