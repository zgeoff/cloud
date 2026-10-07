# Shared by the flake's checks, which source it in their runCommand builders: runs each named
# case on its own and reports it, and gives the cases assertions that say what failed.
# nixos/checks/test-utils-check.nix tests it.

cases_failed=0

# run_case TITLE DIR FUNCTION: runs FUNCTION in the new directory DIR, in a subshell with
# set -euo pipefail, so the case's first failing command fails it and the cases after it still
# run. Prints "ok - TITLE" or "not ok - TITLE", and counts each failure in cases_failed.
run_case() {
  mkdir "$2"
  set +e
  (
    cd "$2"
    set -euo pipefail
    "$3"
  )
  local status=$?
  set -e
  if [ "$status" = 0 ]; then
    echo "ok - $1"
  else
    echo "not ok - $1"
    cases_failed=$((cases_failed + 1))
  fi
}

# require_cases_passed: fails, saying how many, when any case failed
require_cases_passed() {
  if [ "$cases_failed" != 0 ]; then
    echo "$cases_failed case(s) failed" >&2
    return 1
  fi
}

# assert_equals EXPECTED ACTUAL LABEL: fails, printing both, when the two strings differ
assert_equals() {
  if [ "$1" != "$2" ]; then
    printf '%s: expected %q, got %q\n' "$3" "$1" "$2" >&2
    return 1
  fi
}

# assert_files_equal EXPECTED_FILE ACTUAL_FILE: fails, printing the diff, when the files differ
assert_files_equal() {
  diff -u "$1" "$2" >&2
}

# assert_between LOW VALUE HIGH LABEL: fails unless VALUE is an integer from LOW to HIGH
assert_between() {
  if ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt "$1" ] || [ "$2" -gt "$3" ]; then
    printf '%s: expected %s..%s, got %q\n' "$4" "$1" "$3" "$2" >&2
    return 1
  fi
}
