# shellcheck shell=bash
# assert_between <low> <value> <high> <label>: returns 1, printing "<label>: expected
# <low>..<high>, got <value>" (the value quoted with %q) to stderr, unless the value is a
# whole number from low to high.
assert_between() {
  if ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt "$1" ] || [ "$2" -gt "$3" ]; then
    printf '%s: expected %s..%s, got %q\n' "$4" "$1" "$3" "$2" >&2
    return 1
  fi
}
