# shellcheck shell=bash
# create_stub_nixos_ssh <bin>: writes <bin>/ssh, a stand-in for ssh to the NixOS host that
# switch-geoffcloud.sh switches. It logs each call's argv as a JSON line to STUB_LOG and
# answers the nine remote commands the switch runs:
#
# - the kubectl query for the atc gateway pods' images: prints STUB_GATEWAY_IMAGES (images
#   separated by spaces, as jsonpath joins an `[*]` list) with no newline, as kubectl's jsonpath
#   output ends, and nothing when it is unset, as for a selector that matches no pod. Left
#   open, with no cluster sample: whether a real kubectl adds a "No resources found" line on
#   stderr for that empty match, which the switch would pass through. From the
#   second query on it prints STUB_GATEWAY_LATER_IMAGES instead, when that is set, so a case
#   can roll the gateway out between the switch's two checks;
# - the kubectl query for the nixie pods' images: prints STUB_NIXIE_IMAGES the same way, and
#   from the second query on STUB_NIXIE_LATER_IMAGES instead, when that is set;
# - the kubectl exec into nixie-0 that runs nixie health: prints line <n> of STUB_NIXIE_REPORTS
#   for the n-th call, and its last line for every call after, each a report body as nixie's
#   server sends it, and exits 1 with kubectl's message for a report whose status is not ready. With STUB_NIXIE_REPORTS unset, it fails as kubectl does for
#   a pod that does not exist: "Error from server (NotFound): pods "nixie-0" not found" on
#   stderr and exit 1;
# - switch-to-configuration dry-activate: prints STUB_DRY_ACTIVATE, the lines of the units it
#   would stop, reload, restart and start, on stderr, and "would activate the configuration..."
#   when that is unset, the one line a dry-activate with no unit to change prints, then exits 0;
#   or with STUB_DRY_ACTIVATE_LOCKED fails as switch-to-configuration-ng does while another
#   switch holds its lock: "Could not acquire lock" on stderr and exit 11;
# - the profile set, the switch record and switch-to-configuration: prints nothing, or with
#   STUB_ACTIVATE_FAILED_UNITS (unit names separated by spaces) fails as
#   switch-to-configuration-ng does when units failed: "warning: the following units
#   failed: <units>" on stderr, the units sorted by their lower-case names and joined with
#   ", "; then STUB_ACTIVATE_STATUS, the `systemctl status` text of those units, on stdout,
#   when set; then exit 4, which systemd-run --wait --pipe passes back;
# - `readlink /run/current-system`: prints STUB_CURRENT, or with STUB_SSH_DROP_AT_READLINK
#   drops the connection as OpenSSH reports a closed session (exit 255);
# - `systemctl --failed --no-legend --plain`: prints STUB_FAILED_UNITS, or with
#   STUB_FAILED_EXIT fails with systemctl's message and that code;
# - `docker exec imp-host impz image ls --json`: prints STUB_IMPD_IMAGES, the JSON array of impd's
#   image records, and `[]` when that is unset;
# - the `docker exec imp-host sh -c` loop that lists the folders under /var/lib/imp/images holding
#   a rootfs.ext4: prints each name in STUB_IMPD_IMAGE_DIRS (names separated by spaces) on its own
#   line, and nothing when that is unset;
# - with STUB_IMP_HOST_GONE, both docker commands fail as docker does for a container that does
#   not exist: "Error response from daemon: No such container: imp-host" on stderr and exit 1,
#   which ssh passes back.
#
# docker's line was checked on 2026-10-26 against a real docker 29.8.2: `docker exec <a container
# that does not exist> true` printed "Error response from daemon: No such container: <name>" and
# exited 1. Not run against geoffcloud's docker. The image records' shape is impd's ImageSchema
# (zgeoff/impz packages/api/src/schemas/image-schema.ts at v4.2.4 and v5.0.0), which a case
# supplies whole.
#
# With STUB_SSH_PASS=1, a call after it is logged goes through print-ssh-pass-through.sh's
# guard: to the real ssh for a loopback destination, else exit 97. A call without
# `-o BatchMode=yes` or with an unknown remote command ends with exit 97 and "unexpected:
# <argv>" on stderr.
#
# The dry-activate lines were checked on 2026-10-19 against nixpkgs
# 4feb8eb8bf30f323a8a5d285f14ee51d6a7197b1 (nixos/flake.lock): in
# pkgs/by-name/sw/switch-to-configuration-ng/src/main.rs, dry-activate prints each unit list with
# eprintln!("would <verb> the following units: {}", units.join(", ")) (lines 2049-2189), the
# names sorted by their lower-case form, always prints "would activate the configuration...",
# and exits 0. A held lock prints "Could not acquire lock" and calls die() (lines 1823-1827),
# which exits with the errno of the failed non-blocking flock, EWOULDBLOCK, 11 on Linux. Not run
# against a real host. Left open: what the activation script's own dry-activate snippets print.
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
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/print-ssh-pass-through.sh"

create_stub_nixos_ssh() {
  local bin="$1"
  {
    echo '#!/usr/bin/env bash'
    cat << 'STUB'
printf '%s\0' ssh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
if [ "$1 $2" != "-o BatchMode=yes" ]; then echo "unexpected: $*" >&2; exit 97; fi
STUB
    print_ssh_pass_through
    cat << 'STUB'
case "${*:4}" in
  "k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'")
    queries="$(grep -cF 'k3s kubectl -n atc get pods -l app=atc-gateway' "$STUB_LOG")"
    if [ "$queries" -gt 1 ] && [ -n "${STUB_GATEWAY_LATER_IMAGES+set}" ]; then
      printf '%s' "$STUB_GATEWAY_LATER_IMAGES"
    else
      printf '%s' "${STUB_GATEWAY_IMAGES:-}"
    fi
    ;;
  "k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'")
    queries="$(grep -cF 'k3s kubectl -n nixie get pods -l app=nixie' "$STUB_LOG")"
    if [ "$queries" -gt 1 ] && [ -n "${STUB_NIXIE_LATER_IMAGES+set}" ]; then
      printf '%s' "$STUB_NIXIE_LATER_IMAGES"
    else
      printf '%s' "${STUB_NIXIE_IMAGES:-}"
    fi
    ;;
  "k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health")
    if [ -z "${STUB_NIXIE_REPORTS+set}" ]; then
      echo 'Error from server (NotFound): pods "nixie-0" not found' >&2
      exit 1
    fi
    calls="$(grep -cF 'k3s kubectl -n nixie exec nixie-0' "$STUB_LOG")"
    total="$(printf '%s\n' "$STUB_NIXIE_REPORTS" | wc -l)"
    report="$(printf '%s\n' "$STUB_NIXIE_REPORTS" | sed -n "$((calls < total ? calls : total))p")"
    printf '%s\n' "$report"
    # nixie health exits 1 unless the server answers ready, and kubectl says so on stderr
    if [[ "$report" != '{"status":"ready"'* ]]; then
      echo 'command terminated with exit code 1' >&2
      exit 1
    fi
    ;;
  "NIXOS_INSTALL_BOOTLOADER=0 systemd-run "*"/bin/switch-to-configuration'"*" dry-activate")
    if [ -n "${STUB_DRY_ACTIVATE_LOCKED:-}" ]; then
      echo "Could not acquire lock" >&2
      exit 11
    fi
    printf '%s\n' "${STUB_DRY_ACTIVATE:-would activate the configuration...}" >&2
    ;;
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
  "docker exec imp-host impz image ls --json")
    if [ -n "${STUB_IMP_HOST_GONE:-}" ]; then
      echo "Error response from daemon: No such container: imp-host" >&2
      exit 1
    fi
    printf '%s\n' "${STUB_IMPD_IMAGES:-[]}"
    ;;
  "docker exec imp-host sh -c 'cd /var/lib/imp/images && for d in *; do if [ -f \"\$d/rootfs.ext4\" ]; then echo \"\$d\"; fi; done'")
    if [ -n "${STUB_IMP_HOST_GONE:-}" ]; then
      echo "Error response from daemon: No such container: imp-host" >&2
      exit 1
    fi
    if [ -n "${STUB_IMPD_IMAGE_DIRS:-}" ]; then printf '%s\n' $STUB_IMPD_IMAGE_DIRS; fi
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  } > "$bin/ssh"
  chmod +x "$bin/ssh"
}
