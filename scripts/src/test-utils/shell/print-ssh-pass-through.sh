# shellcheck shell=bash
# print_ssh_pass_through: prints the lines an ssh stand-in runs to hand a loopback call to the
# real ssh, for the stand-in's script, after it logs the call and checks `-o BatchMode=yes` as $1
# and $2, so the destination is $3. With STUB_SSH_PASS=1, a call to a loopback destination
# (ssh://<user>@127.0.0.1:<port>) goes to the real ssh, with -F /dev/null so no ssh config on the
# machine applies, so a case reaches a real refused connection. An argument after the destination
# that starts with `-`, which OpenSSH would still read as an option, ends the call with exit 97
# before the real ssh runs, and so does a call to any other destination, each with "unexpected:
# <argv>" on stderr. The real ssh is the one on the fixed system path (/usr/local/bin, /usr/bin,
# /bin) when the lines are printed, never one from the caller's PATH. Without STUB_SSH_PASS the
# lines do nothing, and the stand-in goes on to its own answers.
print_ssh_pass_through() {
  local real_ssh
  real_ssh="$(PATH=/usr/local/bin:/usr/bin:/bin command -v ssh || true)"
  printf 'real_ssh=%q\n' "$real_ssh"
  cat << 'GUARD'
if [ -n "${STUB_SSH_PASS:-}" ]; then
  for arg in "${@:4}"; do
    if [[ "$arg" == -* ]]; then echo "unexpected: $*" >&2; exit 97; fi
  done
  if [ -n "$real_ssh" ] && [[ "$3" =~ ^ssh://[a-z]+@127\.0\.0\.1:[0-9]+$ ]]; then exec "$real_ssh" -F /dev/null "$@"; fi
  echo "unexpected: $*" >&2
  exit 97
fi
GUARD
}
