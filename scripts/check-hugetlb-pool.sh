#!/usr/bin/env bash
# Check that the host reserved the whole hugetlb pool its system configures. switch-geoffcloud.sh
# runs it after the activation, and before it moves deployed/host:
#
#   bash scripts/check-hugetlb-pool.sh <host>
#
# NixOS writes boot.kernel.sysctl into /etc/sysctl.d/60-nixos.conf as `<key>=<value>` lines, and
# systemd-sysctl applies a changed vm.nr_hugepages at the activation. The kernel then reserves only
# the pages it finds free and contiguous, and vm.nr_hugepages reads back the pages it reserved, so a
# live switch on fragmented memory can leave the pool short. impd refuses each boot and wake that
# the free pool cannot hold, and a reboot reserves the whole pool early in boot.
# It prints one line and exits 0 when the host configures no pool or reserved all of it. It exits 1
# and names both counts when the pool is short, or when either count is not a number; an ssh
# failure stops it with ssh's exit code.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: check-hugetlb-pool.sh <host>" >&2
  exit 2
fi
host="$1"

# the reserved count, then the configured one, which is empty when the system sets none
counts="$(ssh -o BatchMode=yes "$host" \
  "sysctl -n vm.nr_hugepages; sed -n 's/^vm\\.nr_hugepages=//p' /etc/sysctl.d/60-nixos.conf")"
{
  read -r reserved || true
  read -r configured || true
} <<< "$counts"

if [ -z "${configured:-}" ]; then
  echo "== $host configures no hugetlb pool"
  exit 0
fi
if [[ ! "${reserved:-}" =~ ^[0-9]+$ || ! "$configured" =~ ^[0-9]+$ ]]; then
  echo "$host reports '${reserved:-}' reserved and '$configured' configured hugetlb pages," \
    "which are not both numbers" >&2
  exit 1
fi
if [ "$reserved" -lt "$configured" ]; then
  echo "$host reserved $reserved of its $configured hugetlb pages, so impd refuses each boot and" \
    "wake past them; reboot the host, which reserves the whole pool early in boot, then switch" \
    "again" >&2
  exit 1
fi
echo "== $host reserved its whole hugetlb pool: $configured pages"
