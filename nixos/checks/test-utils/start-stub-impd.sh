# shellcheck shell=bash
# start_stub_impd <stand-in> <arg>…: starts the impd stand-in <stand-in> (run-stub-impd.py or
# run-stub-hung-impd.py) with python3 in the background, under env -i with PATH and the HOME and
# TMPDIR of the case's own home and tmp directories, which the case makes first. It sets the
# global stub_pid to the stand-in's process and port to the port it prints, read through the fifo
# port.fifo in the working directory on fd 3 within 5 s, and sets the EXIT trap to kill the
# stand-in, so a case may stop it earlier. Call it as a plain statement in the case itself, never
# in $(…), so the globals and the trap reach the case. nixos/checks/test-utils-check.nix tests it.
start_stub_impd() {
  mkfifo port.fifo
  exec 3<> port.fifo
  env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" python3 "$@" >&3 &
  stub_pid=$!
  trap 'kill "$stub_pid" 2> /dev/null || true' EXIT
  # shellcheck disable=SC2034 # the case reads port
  read -r -t 5 -u 3 port
}
