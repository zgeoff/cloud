# shellcheck shell=bash
# assert_not_equals <unexpected> <actual> <label>: returns 1, printing "<label>: expected
# anything but <unexpected>" (quoted with %q) to stderr, when the two strings are equal.
assert_not_equals() {
  if [ "$1" = "$2" ]; then
    printf '%s: expected anything but %q\n' "$3" "$1" >&2
    return 1
  fi
}
