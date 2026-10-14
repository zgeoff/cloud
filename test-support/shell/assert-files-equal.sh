# shellcheck shell=bash
# assert_files_equal <expected-file> <actual-file>: returns 1, printing their unified diff to
# stderr, when the files differ.
assert_files_equal() {
  diff -u "$1" "$2" >&2
}
