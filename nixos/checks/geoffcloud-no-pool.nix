# geoffcloud's own NixOS configuration booted in a VM that has no pool disk, as the host is after it
# loses vdb (docs/runbooks/lost-disk.md). The VM imports the host's modules as they are, and mounts
# every entry of the host's fileSystems but the root disk's, so a mount or a unit that needs the
# pool at boot fails the check. The runbook's starting state is the contract: the host boots and
# answers SSH, with k3s, imp-host, the atc daemon and the preview service stopped, and nothing
# written into the empty mount points on the root disk.
#
# The VM differs from the host in two ways that are not about the pool. It reaches no network, so
# imp-host-image fails its pull and host-build-lag fails its query of GitHub; the check allows
# those two failures by name. tailscaled-autoconnect is off: the VM's tailscaled has no node state,
# so tailscale up would wait out its start timeout, where the host's node state on vda logs it in.
#
# The same boot checks the hugetlb cap for imp guest memory: a mapping with Firecracker's hugetlb
# flags gets its 2 MiB pages on demand and frees them on exit, and without the cap it dies of
# SIGBUS, as a Firecracker guest would. It needs KVM: run `bun run test:nixos geoffcloud-no-pool`.
{
  nixpkgs,
  geoffcloud,
  geoffcloudModules,
}:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;
  # every mount but the root disk's, which the VM's own root disk stands in for
  poolMounts = removeAttrs geoffcloud.config.fileSystems [
    "/"
    "/boot"
  ];
  stoppedServices = [
    "k3s"
    "imp-host"
    "atc-daemon"
    "preview"
  ];
  # maps PAGES 2 MiB pages as Firecracker maps hugetlb guest memory (MAP_PRIVATE, MAP_ANONYMOUS,
  # MAP_NORESERVE, MAP_HUGETLB and MAP_HUGE_2MB), writes one byte to each, and prints the kernel's
  # hugetlb counts while it holds them
  mapHugetlb = pkgs.writeText "map-hugetlb.py" ''
    import json
    import mmap
    import sys

    size = int(sys.argv[1]) * 2 * 1024 * 1024
    flags = 0x02 | 0x20 | 0x4000 | 0x40000 | (21 << 26)
    memory = mmap.mmap(-1, size, flags=flags, prot=mmap.PROT_READ | mmap.PROT_WRITE)
    for offset in range(0, size, 2 * 1024 * 1024):
        memory[offset] = 1
    counts = dict(line.split(":") for line in open("/proc/meminfo") if line.startswith("HugePages_"))
    print(json.dumps({name: int(value) for name, value in counts.items()}, sort_keys=True))
  '';
in
pkgs.testers.runNixOSTest {
  name = "geoffcloud-no-pool";
  nodes.machine = {
    imports = geoffcloudModules;
    # the VM mounts virtualisation.fileSystems in place of fileSystems
    virtualisation.fileSystems = poolMounts;
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    systemd.services.tailscaled-autoconnect.enable = false;
  };

  testScript = ''
    services = ${builtins.toJSON stoppedServices}
    mount_paths = ${builtins.toJSON (lib.attrNames poolMounts)}
    # the units that fail because the VM reaches no network; host-build-lag runs from a timer, so
    # it may not have run yet
    offline_failures = {"imp-host-image.service", "host-build-lag.service"}


    machine.wait_for_unit("multi-user.target")


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it boots to multi-user with sshd answering and no ordering cycle"):
        machine.wait_for_unit("sshd.service")
        machine.wait_for_open_port(22)

        _, state = machine.execute("systemctl is-system-running --wait")
        assert state.strip() == "degraded", f"the system is {state.strip()!r}"
        cycles = machine.succeed("journalctl -b -q --no-pager --grep 'ordering cycle' || true").strip()
        assert cycles == "", f"the boot has an ordering cycle: {cycles}"


    with subtest("it fails only the pool's import, beside the units the VM's lack of a network fails"):
        failed = set(machine.succeed("systemctl list-units --failed --plain --no-legend --full | cut -d' ' -f1").split())

        assert "zfs-import-tank.service" in failed, f"the failed units are {sorted(failed)}"
        assert failed - offline_failures == {"zfs-import-tank.service"}, f"the failed units are {sorted(failed)}"
        import_log = machine.succeed("journalctl -b -u zfs-import-tank.service --no-pager")
        assert "cannot import 'tank': no such pool available" in import_log, import_log


    with subtest("it never starts k3s, imp-host, the atc daemon or the preview service"):
        states = machine.succeed(f"systemctl show -p ActiveState --value {' '.join(services)}").split()
        left_inactive = machine.succeed(f"systemctl show -p InactiveExitTimestampMonotonic --value {' '.join(services)}").split()

        assert states == ["inactive"] * len(services), f"the services are {states}"
        assert left_inactive == ["0"] * len(services), f"the services left inactive at {left_inactive}"


    with subtest("it mounts nothing of the pool and writes nothing into the mount points on the root disk"):
        mounted = machine.succeed(f"for path in {' '.join(mount_paths)}; do ! mountpoint -q $path || echo $path; done").split()
        left = machine.succeed(f"find {' '.join(mount_paths)} -mindepth 1 2>/dev/null | sort || true").split()

        assert mounted == [], f"mounted: {mounted}"
        assert left == [], f"the root disk holds {left}"


    with subtest("it caps on-demand 2 MiB hugetlb pages at the imps' 20 GiB RAM budget, with none made at boot"):
        cap = machine.succeed("sysctl -n vm.nr_overcommit_hugepages").strip()
        total = machine.succeed("sed -n 's/^HugePages_Total: *//p' /proc/meminfo").strip()

        assert cap == "10240", f"the cap is {cap!r} pages"
        assert total == "0", f"the boot made {total!r} hugetlb pages"


    with subtest("it backs a Firecracker-style hugetlb mapping with on-demand pages and frees them on exit"):
        held = machine.succeed("${pkgs.python3}/bin/python3 -I ${mapHugetlb} 64").strip()
        total = machine.succeed("sed -n 's/^HugePages_Total: *//p' /proc/meminfo").strip()

        assert held == '{"HugePages_Free": 0, "HugePages_Rsvd": 0, "HugePages_Surp": 64, "HugePages_Total": 64}', held
        assert total == "0", f"{total!r} hugetlb pages outlive the mapping"


    with subtest("it kills the same mapping with SIGBUS once the cap is 0"):
        machine.succeed("sysctl -w vm.nr_overcommit_hugepages=0")
        status, output = machine.execute("${pkgs.python3}/bin/python3 -I ${mapHugetlb} 64 2>&1")

        assert status == 135, f"the mapping exited {status}: {output}"
  '';
}
