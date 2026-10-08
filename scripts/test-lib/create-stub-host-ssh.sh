# shellcheck shell=bash
# create_stub_host_ssh <bin>: writes <bin>/ssh, a stand-in for ssh to the host that
# install-atc-gateway-credentials.sh installs credentials on. "The host" is STUB_TREE/host:
# the stand-in runs each remote command it knows there, with its own stdin, copies its
# stdout to STUB_TREE/host-output, and returns its exit code. It logs each call's argv as a
# JSON line to STUB_TREE/calls.
#
# Like real ssh, it forwards none of the caller's environment or working directory: the
# command runs from STUB_TREE/host under `env -i`, with the host's login environment, the
# lines of STUB_TREE/host/environment (NAME=value, as pam_env reads /etc/environment) when
# that file exists, then PATH (STUB_HOST_BIN, then /usr/bin and /bin) and HOME, which is
# STUB_TREE/host/root, never the real /root, and which the stand-in creates when missing.
# The only other variables it passes are the host stand-ins' own settings, which stand
# for the host's state, not the caller's: STUB_TREE, STUB_IMPD_FAIL_AT,
# STUB_SECRET_ADD_ERROR, STUB_TOKEN_NEW_ERROR and STUB_MINTED (create-stub-imp-host-docker.sh),
# and STUB_GOOD_TOKEN, STUB_WHOAMI_STATUS and STUB_WHOAMI_BODY (create-stub-impd-curl.sh),
# each only when set.
#
# With STUB_SSH_PASS=1, a call to a loopback destination (ssh://<user>@127.0.0.1:<port>)
# goes to the real ssh after it is logged, with -F /dev/null so no ssh config on the
# machine applies, so a case reaches a real refused connection. An argument after the
# destination that starts with `-`, which OpenSSH would still read as an option, ends the
# call with exit 97 before the real ssh runs. The real ssh is the one on
# the fixed system path (/usr/local/bin, /usr/bin, /bin) when the stand-in is created,
# never one from the caller's PATH. A call without `-o BatchMode=yes`, to a host other than
# STUB_HOST, with a remote command it does not know, or with STUB_SSH_PASS=1 to any
# destination but loopback ends with exit 97 and "unexpected: <argv>" on stderr. A known
# command runs only when ssh, scp, sftp, rsync and tailscale each resolve to a stand-in in
# STUB_HOST_BIN and the command names none of them as a word or path and has no `command -p`;
# otherwise the call ends with exit 97 before any interception, and runs nothing.
#
# Interceptions, each logged as a one-element line, change the host at a moment no real
# state reaches: STUB_SSH_DROP_AT_WHOAMI drops the connection on the whoami check (exit
# 255 and OpenSSH's closed-session line); STUB_REMOVE_TOKEN_AT_WHOAMI removes the saved
# token just before it; STUB_READONLY_AT_BEARER_WRITE makes the secrets directory
# read-only just before the bearer is written; STUB_ALTER_BEARER_BEFORE_SUM appends to the
# written bearer just before its checksum; STUB_REMOVE_BEARER_BEFORE_STAT removes it
# before the final stat.
create_stub_host_ssh() {
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
if [ "$3" != "$STUB_HOST" ]; then echo "unexpected: $*" >&2; exit 97; fi
remote="${*:4}"
dir="$ATC_CREDENTIALS_DIR"
case "$remote" in
  true | "docker exec imp-host imp "*" --json" | "docker exec -i imp-host imp secret add glm "* | \
    "install -d -m 0700 -o root -g root $dir" | "ls $dir" | "sha256sum $dir/gateway-token" | \
    "umask 077; t=\$(mktemp $dir/.gateway-token.XXXXXX);"* | \
    "set -euo pipefail; export LC_ALL=C"*"/rpc/tokens/whoami" | \
    "set -euo pipefail; umask 077; t=\$(mktemp $dir/.imp-token.XXXXXX)"* | \
    "stat -c '%n %U %a %s bytes' $dir $dir/gateway-token $dir/imp-token") ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
# the remote command runs with /usr/bin on PATH, so before any interception changes the host,
# every remote tool must resolve to a stand-in in STUB_HOST_BIN, and the command must not name
# one by path or bypass PATH with `command -p`
for tool in ssh scp sftp rsync tailscale; do
  if [ "$(PATH="$STUB_HOST_BIN:/usr/bin:/bin" command -v "$tool" || true)" != "$STUB_HOST_BIN/$tool" ] ||
    [ ! -x "$STUB_HOST_BIN/$tool" ]; then
    echo "unexpected: $tool on the host PATH is not a stand-in in $STUB_HOST_BIN" >&2
    exit 97
  fi
done
if [[ "$remote" =~ (^|[^A-Za-z0-9_.-])(ssh|scp|sftp|rsync|tailscale)([^A-Za-z0-9_-]|$) ]] ||
  [[ "$remote" == *"command -p"* ]]; then
  echo "unexpected: $*" >&2
  exit 97
fi
case "$remote" in
  *tokens/whoami*)
    if [ -n "${STUB_SSH_DROP_AT_WHOAMI:-}" ]; then
      echo '["ssh-dropped-at-whoami"]' >> "$STUB_TREE/calls"
      printf 'Connection to %s closed by remote host.\r\n' "${STUB_HOST#*@}" >&2
      exit 255
    fi
    if [ -n "${STUB_REMOVE_TOKEN_AT_WHOAMI:-}" ]; then
      rm -f "$dir/imp-token"
      echo '["imp-token-removed-at-whoami"]' >> "$STUB_TREE/calls"
    fi
    ;;
  "umask 077; t="*)
    if [ -n "${STUB_READONLY_AT_BEARER_WRITE:-}" ]; then
      chmod 0500 "$dir"
      echo '["secrets-dir-made-read-only"]' >> "$STUB_TREE/calls"
    fi
    ;;
  "sha256sum "*)
    if [ -n "${STUB_ALTER_BEARER_BEFORE_SUM:-}" ]; then
      chmod u+w "$dir/gateway-token"
      echo altered >> "$dir/gateway-token"
      echo '["gateway-token-altered"]' >> "$STUB_TREE/calls"
    fi
    ;;
  "stat "*)
    if [ -n "${STUB_REMOVE_BEARER_BEFORE_STAT:-}" ]; then
      rm -f "$dir/gateway-token"
      echo '["gateway-token-removed-before-stat"]' >> "$STUB_TREE/calls"
    fi
    ;;
esac
host_env=()
if [ -f "$STUB_TREE/host/environment" ]; then
  while IFS= read -r line; do
    if [ -n "$line" ]; then host_env+=("$line"); fi
  done < "$STUB_TREE/host/environment"
fi
for name in STUB_TREE STUB_IMPD_FAIL_AT STUB_SECRET_ADD_ERROR STUB_TOKEN_NEW_ERROR STUB_MINTED \
  STUB_GOOD_TOKEN STUB_WHOAMI_STATUS STUB_WHOAMI_BODY; do
  if [ -n "${!name+set}" ]; then host_env+=("$name=${!name}"); fi
done
if [ ! -d "$STUB_TREE/host/root" ]; then mkdir "$STUB_TREE/host/root" || exit 97; fi
cd "$STUB_TREE/host" || exit 97
env -i "${host_env[@]}" PATH="$STUB_HOST_BIN:/usr/bin:/bin" HOME="$STUB_TREE/host/root" \
  bash -c "$remote" | tee -a "$STUB_TREE/host-output"
exit "${PIPESTATUS[0]}"
STUB
  } > "$bin/ssh"
  chmod +x "$bin/ssh"
}
