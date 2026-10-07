# shellcheck shell=bash
# create_stub_nixos_ssh <bin>: writes <bin>/ssh, a stand-in for ssh to the NixOS host that
# switch-geoffcloud.sh switches. It logs each call's argv as a JSON line to STUB_LOG and
# answers the three remote commands the switch runs:
#
# - the profile set and switch-to-configuration: prints nothing, or with
#   STUB_ACTIVATE_EXIT prints nixos's activation warning and exits with that code, which
#   systemd-run --wait --pipe passes back;
# - `readlink /run/current-system`: prints STUB_CURRENT, or with STUB_SSH_DROP_AT_READLINK
#   drops the connection as OpenSSH reports a closed session (exit 255);
# - `systemctl --failed --no-legend --plain`: prints STUB_FAILED_UNITS, or with
#   STUB_FAILED_EXIT fails with systemctl's message and that code.
#
# With STUB_SSH_PASS=1, a call to a loopback destination (ssh://<user>@127.0.0.1:<port>)
# goes to the real ssh after it is logged, with -F /dev/null so no ssh config on the
# machine applies, so a case reaches a real refused connection. An argument after the
# destination that starts with `-`, which OpenSSH would still read as an option, ends the
# call with exit 97 before the real ssh runs. The real ssh is the one on
# the fixed system path (/usr/local/bin, /usr/bin, /bin) when the stand-in is created,
# never one from the caller's PATH. A call without
# `-o BatchMode=yes`, an unknown remote command, or a pass-through to any other
# destination ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_nixos_ssh() {
  local bin="$1" real_ssh
  real_ssh="$(PATH=/usr/local/bin:/usr/bin:/bin command -v ssh || true)"
  {
    printf '#!/usr/bin/env bash\nreal_ssh=%q\n' "$real_ssh"
    cat << 'STUB'
printf '%s\0' ssh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
if [ "$1 $2" != "-o BatchMode=yes" ]; then echo "unexpected: $*" >&2; exit 97; fi
if [ -n "${STUB_SSH_PASS:-}" ]; then
  for arg in "${@:4}"; do
    if [[ "$arg" == -* ]]; then echo "unexpected: $*" >&2; exit 97; fi
  done
  if [ -n "$real_ssh" ] && [[ "$3" =~ ^ssh://[a-z]+@127\.0\.0\.1:[0-9]+$ ]]; then exec "$real_ssh" -F /dev/null "$@"; fi
  echo "unexpected: $*" >&2
  exit 97
fi
case "${*:4}" in
  "nix-env -p /nix/var/nix/profiles/system --set "*"/bin/switch-to-configuration' switch")
    if [ -n "${STUB_ACTIVATE_EXIT:-}" ]; then
      echo "warning: error(s) occurred while switching to the new configuration" >&2
      exit "$STUB_ACTIVATE_EXIT"
    fi
    ;;
  "readlink /run/current-system")
    if [ -n "${STUB_SSH_DROP_AT_READLINK:-}" ]; then
      printf 'Connection to %s closed by remote host.\r\n' "${3#*@}" >&2
      exit 255
    fi
    printf '%s\n' "$STUB_CURRENT"
    ;;
  "systemctl --failed --no-legend --plain")
    if [ -n "${STUB_FAILED_EXIT:-}" ]; then
      echo "Failed to list units: Connection timed out" >&2
      exit "$STUB_FAILED_EXIT"
    fi
    if [ -n "${STUB_FAILED_UNITS:-}" ]; then printf '%s\n' "$STUB_FAILED_UNITS"; fi
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  } > "$bin/ssh"
  chmod +x "$bin/ssh"
}
