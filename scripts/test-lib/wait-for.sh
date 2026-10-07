# shellcheck shell=bash
# wait_for <seconds> <what> <command...>: runs the command every 50 ms until it succeeds,
# for at most <seconds>; past that deadline it prints "timed out after <seconds>s
# waiting for <what>" to stderr and returns 1.
wait_for() {
  local seconds="$1" what="$2" deadline
  shift 2
  deadline=$((SECONDS + seconds))
  until "$@"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "timed out after ${seconds}s waiting for $what" >&2
      return 1
    fi
    sleep 0.05
  done
}
