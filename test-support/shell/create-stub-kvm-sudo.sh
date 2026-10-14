# shellcheck shell=bash
# create_stub_kvm_sudo <bin>: writes <bin>/sudo, a stand-in for the sudo that open-kvm.sh calls to
# write the KVM udev rule and reload udev. It runs nothing as root and touches no file outside the
# case tree. It logs each call's argv as a JSON line to STUB_TREE/calls:
#
# - `tee /etc/udev/rules.d/99-kvm4all.rules` writes its stdin to STUB_TREE/rules, in place of the
#   rule file, and prints it, as tee does;
# - `udevadm control --reload-rules` and `udevadm trigger --name-match=kvm` print nothing, as udevadm
#   does on success;
# - with STUB_SUDO_DENIED set, every call prints the two lines sudo prints when it needs a password
#   and has no terminal, and exits 1, as sudo 1.9.17p2 did on 2026-10-14 (`sudo -k true` with stdin
#   from /dev/null and no controlling terminal); a hosted runner's sudo needs no password;
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_kvm_sudo() {
  local bin="$1"
  cat > "$bin/sudo" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' sudo "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
if [ -n "${STUB_SUDO_DENIED:-}" ]; then
  echo "sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper" >&2
  echo "sudo: a password is required" >&2
  exit 1
fi
case "$*" in
  "tee /etc/udev/rules.d/99-kvm4all.rules") tee "$STUB_TREE/rules" ;;
  "udevadm control --reload-rules" | "udevadm trigger --name-match=kvm") ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/sudo"
}
