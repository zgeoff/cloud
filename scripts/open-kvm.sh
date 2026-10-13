#!/usr/bin/env bash
# Opens /dev/kvm to every user on a GitHub-hosted Linux runner, as GitHub's changelog of 2024-04-02
# documents: it writes a udev rule that gives the device mode 0666, reloads udev's rules and
# triggers the device. QEMU, which runs as a nixbld user in the pinned Nix container (nix-image.sh), otherwise
# gets "Permission denied" on the device and falls back to emulation. The NixOS checks workflow
# runs it before the checks; it needs passwordless sudo, and a sudo failure fails it.
#
#   bash scripts/open-kvm.sh
set -euo pipefail

echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm
