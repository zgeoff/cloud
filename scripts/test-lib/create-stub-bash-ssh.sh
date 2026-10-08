# shellcheck shell=bash
# create_stub_bash_ssh <bin>: writes <bin>/ssh, a stand-in for ssh to a host that runs one
# `bash -c <script> _ <args>…` command, as install-imp-dns-token.sh sends it. "The host" is
# STUB_TREE/host: the stand-in hands the command to bash here, as the remote login shell
# would, with its own stdin, and returns its exit code. Like real ssh, it forwards none of
# the caller's environment or working directory: the command runs from STUB_TREE/host under
# `env -i` with only PATH (STUB_HOST_BIN, then /usr/bin and /bin) and HOME set, HOME being
# STUB_TREE/host/root, which it creates, never the real /root. It logs each call's argv as
# a JSON line to STUB_TREE/calls.
#
# With STUB_SSH_PASS=1, a call to a loopback destination (ssh://<user>@127.0.0.1:<port>)
# goes to the real ssh after it is logged, with -F /dev/null so no ssh config on the
# machine applies, so a case reaches a real refused connection. An argument after the
# destination that starts with `-`, which OpenSSH would still read as an option, ends the
# call with exit 97 before the real ssh runs. The real ssh is the one on the fixed system
# path (/usr/local/bin, /usr/bin, /bin) when the stand-in is created, never one from the
# caller's PATH. A call without `-o BatchMode=yes`, to a host other than STUB_HOST, with
# more than one remote argument or one that does not start with `bash -c `, or with
# STUB_SSH_PASS=1 to any destination but loopback ends with exit 97 and "unexpected:
# <argv>" on stderr. The command runs only when ssh, scp, sftp, rsync and tailscale each
# resolve to a stand-in in STUB_HOST_BIN and the command names none of them as a word or
# path and has no `command -p`; otherwise the call ends with exit 97 and runs nothing.
create_stub_bash_ssh() {
  local bin="$1" real_ssh
  real_ssh="$(PATH=/usr/local/bin:/usr/bin:/bin command -v ssh || true)"
  {
    printf '#!/usr/bin/env bash\nreal_ssh=%q\n' "$real_ssh"
    cat << 'STUB'
printf '%s\0' ssh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
if [ "$1 $2" != "-o BatchMode=yes" ]; then echo "unexpected: $*" >&2; exit 97; fi
if [ -n "${STUB_SSH_PASS:-}" ]; then
  for arg in "${@:4}"; do
    if [[ "$arg" == -* ]]; then echo "unexpected: $*" >&2; exit 97; fi
  done
  if [ -n "$real_ssh" ] && [[ "$3" =~ ^ssh://[a-z]+@127\.0\.0\.1:[0-9]+$ ]]; then exec "$real_ssh" -F /dev/null "$@"; fi
  echo "unexpected: $*" >&2
  exit 97
fi
if [ "$#" != 4 ] || [ "$3" != "$STUB_HOST" ] || [[ "$4" != "bash -c "* ]]; then echo "unexpected: $*" >&2; exit 97; fi
for tool in ssh scp sftp rsync tailscale; do
  if [ "$(PATH="$STUB_HOST_BIN:/usr/bin:/bin" command -v "$tool" || true)" != "$STUB_HOST_BIN/$tool" ] ||
    [ ! -x "$STUB_HOST_BIN/$tool" ]; then
    echo "unexpected: $tool on the host PATH is not a stand-in in $STUB_HOST_BIN" >&2
    exit 97
  fi
done
if [[ "$4" =~ (^|[^A-Za-z0-9_.-])(ssh|scp|sftp|rsync|tailscale)([^A-Za-z0-9_-]|$) ]] ||
  [[ "$4" == *"command -p"* ]]; then
  echo "unexpected: $*" >&2
  exit 97
fi
mkdir -p "$STUB_TREE/host/root"
cd "$STUB_TREE/host" || exit 97
exec env -i PATH="$STUB_HOST_BIN:/usr/bin:/bin" HOME="$STUB_TREE/host/root" bash -c "$4"
STUB
  } > "$bin/ssh"
  chmod +x "$bin/ssh"
}
