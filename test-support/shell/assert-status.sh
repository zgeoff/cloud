# shellcheck shell=bash
# assert_status <expected> <actual>: returns 1, printing "exit <actual>, want <expected>" to
# stderr, when the exit status <actual> is not <expected>.
assert_status() {
  if [ "$2" != "$1" ]; then
    echo "exit $2, want $1" >&2
    return 1
  fi
}
