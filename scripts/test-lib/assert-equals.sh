# shellcheck shell=bash
# assert_equals <expected> <actual> <label>: returns 1, printing "<label>: expected <expected>,
# got <actual>" (each quoted with %q) to stderr, when the two strings differ.
assert_equals() {
  if [ "$1" != "$2" ]; then
    printf '%s: expected %q, got %q\n' "$3" "$1" "$2" >&2
    return 1
  fi
}
