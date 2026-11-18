# shellcheck shell=bash
# assert_missing <path> <label>: returns 1, printing "<label>: expected no <path>" (quoted
# with %q) to stderr, when anything is at the path, a dangling symlink included.
assert_missing() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    printf '%s: expected no %q\n' "$2" "$1" >&2
    return 1
  fi
}
