# shellcheck shell=bash
# wait_for <seconds> <what> <command...>: runs the command every 50 ms until it succeeds,
# for at most <seconds>; past that deadline it prints "timed out after <seconds>s
# waiting for <what>" to stderr and returns 1.
#
# Its clock and its pause are commands: WAIT_FOR_CLOCK prints the current second and
# WAIT_FOR_SLEEP takes the pause in seconds. They default to bash's SECONDS and the real
# sleep; only wait_for's own tests (and tests of helpers built on it) set them, so a
# timeout case steps a fake clock instead of waiting out real seconds.
wait_for() {
  local seconds="$1" what="$2" pause="${WAIT_FOR_SLEEP:-sleep}" now deadline
  shift 2
  if [ -n "${WAIT_FOR_CLOCK:-}" ]; then now="$("$WAIT_FOR_CLOCK")"; else now="$SECONDS"; fi
  deadline=$((now + seconds))
  until "$@"; do
    if [ -n "${WAIT_FOR_CLOCK:-}" ]; then now="$("$WAIT_FOR_CLOCK")"; else now="$SECONDS"; fi
    if [ "$now" -ge "$deadline" ]; then
      echo "timed out after ${seconds}s waiting for $what" >&2
      return 1
    fi
    "$pause" 0.05
  done
}
