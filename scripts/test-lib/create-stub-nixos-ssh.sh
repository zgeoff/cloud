# shellcheck shell=bash
# create_stub_nixos_ssh <bin>: writes <bin>/ssh, a stand-in for ssh to the NixOS host that
# switch-geoffcloud.sh switches. It logs each call's argv as a JSON line to STUB_LOG and
# answers the three remote commands the switch runs:
#
# - the profile set and switch-to-configuration: prints nothing, or with
#   STUB_ACTIVATE_FAILED_UNITS (unit names separated by spaces) fails as
#   switch-to-configuration-ng does when units failed: "warning: the following units
#   failed: <units>" on stderr, the units sorted by their lower-case names and joined with
#   ", "; then STUB_ACTIVATE_STATUS, the `systemctl status` text of those units, on stdout,
#   when set; then exit 4, which systemd-run --wait --pipe passes back;
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
#
# The dropped session's line was checked on 2026-10-08 against OpenSSH's source and a real
# ssh: clientloop.c's quit_message("Connection to %s closed by remote host.") (line 805 at
# V_9_6_P1, line 804 at V_10_5_P1) appends CR LF, and ssh exits 255 when the session ends
# without an exit status. OpenSSH 10.5p1 printed exactly that line, with the host as given,
# and exited 255 when a loopback sshd's session process was killed mid-command. 9.6p1 (CI's
# ubuntu-24.04 runner) was not run; its source line is the same. Left open: the source prints
# this line only when the read fails with EPIPE, and "Read from remote host <host>: <error>"
# for other failures, so which line a real drop gives depends on how the connection ends.
#
# systemctl's line was checked on 2026-10-08 against systemd v260.4's source, the systemd of
# nixpkgs 4feb8eb8bf30f323a8a5d285f14ee51d6a7197b1 (nixos/flake.lock):
# src/systemctl/systemctl-util.c line 240 prints "Failed to list units: %s" with
# bus_error_message, and src/shared/main-func.h maps the negative error to exit 1. Not run
# against a real systemd, which needs a bus that times out. Left open: the reason is the bus
# error's own message when it carries one, else strerror(ETIMEDOUT), "Connection timed out".
#
# The failed switch was checked on 2026-10-08 against nixpkgs
# 4feb8eb8bf30f323a8a5d285f14ee51d6a7197b1 (nixos/flake.lock), whose
# nixos/modules/system/activation/switchable-system.nix links switch-to-configuration-ng as
# the only switch-to-configuration. Its pkgs/by-name/sw/switch-to-configuration-ng/src/main.rs
# (lines 2659-2673) sorts the failed units with sort_by_key(to_lowercase), prints
# eprintln!("warning: the following units failed: {}", units.join(", ")), spawns the new
# system's `systemctl status --no-pager --full <units>` with the switch's own stdout and
# stderr, ignores that command's status, and exits 4. Its "switching to system configuration
# … failed (status 4)" line goes to syslog (syslog::init, line 1829), not stderr. Left open:
# what `systemctl status` prints, which is systemd's and the units' own, so a case supplies it;
# and the lines a real switch prints before the warning on every run, failed or not
# ("activating the configuration...", the activate script's own output, "reloading user units
# for <user>..." for each logged-in user, "restarting sysinit-reactivation.target"), which
# depend on the host's state and which the stand-in leaves out on both paths.
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
    if [ -n "${STUB_ACTIVATE_FAILED_UNITS:-}" ]; then
      read -ra failed <<< "$STUB_ACTIVATE_FAILED_UNITS"
      sorted="$(for unit in "${failed[@]}"; do printf '%s\t%s\n' "${unit,,}" "$unit"; done |
        LC_ALL=C sort -s -t $'\t' -k1,1 | cut -f2 | paste -sd, - | sed 's/,/, /g')"
      echo "warning: the following units failed: $sorted" >&2
      if [ -n "${STUB_ACTIVATE_STATUS:-}" ]; then printf '%s\n' "$STUB_ACTIVATE_STATUS"; fi
      exit 4
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
