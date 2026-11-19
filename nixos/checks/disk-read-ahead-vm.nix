# services.disk-read-ahead on a booted VM with three virtio disks: the module sets vda's read-ahead
# by its kernel name, and vdb's by a link an earlier udev rule makes, as ZFS's rule makes the
# rancher zvol's on geoffcloud. It sets both through the kernel's own sysfs, after a device event
# and after a start of its unit, as a switch starts it. It skips a listed disk that is absent, and
# leaves vdc's read-ahead alone.
# It needs KVM: run `bun run test:nixos disk-read-ahead-vm`.
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;

  # stands in for ZFS's 60-zvol.rules, which links /dev/zvol/<pool>/<volume> to its zd device
  linkRule = pkgs.writeTextFile {
    name = "disk-read-ahead-vm-link";
    destination = "/etc/udev/rules.d/60-disk-read-ahead-vm-link.rules";
    text = ''
      SUBSYSTEM=="block", KERNEL=="vdb", SYMLINK+="zvol/tank/cloud/rancher"
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "disk-read-ahead-vm";
  nodes.machine = {
    imports = [ ../modules/disk-read-ahead.nix ];
    services.disk-read-ahead = {
      enable = true;
      devices = [
        "vda"
        "zvol/tank/cloud/rancher"
        "zvol/tank/cloud/absent"
      ];
    };
    services.udev.packages = [ linkRule ];
    # vdb, the linked disk, and vdc, a disk the module does not list
    virtualisation.emptyDiskImages = [
      64
      64
    ];
  };

  testScript = ''
    def read_ahead(disk):
        return machine.succeed(f"cat /sys/block/{disk}/queue/read_ahead_kb").strip()


    machine.wait_for_unit("multi-user.target", timeout=300)


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it sets the listed disks' read-ahead at boot, and skips the absent one"):
        machine.wait_for_unit("disk-read-ahead.service", timeout=60)
        link = machine.succeed("readlink -f /dev/zvol/tank/cloud/rancher").strip()

        assert link == "/dev/vdb", f"the link points at {link!r}"
        assert read_ahead("vda") == "128", f"vda's read-ahead is {read_ahead('vda')!r} KiB"
        assert read_ahead("vdb") == "128", f"vdb's read-ahead is {read_ahead('vdb')!r} KiB"


    for disk in ["vda", "vdb"]:
        with subtest(f"it sets {disk}'s read-ahead again after a change event of the disk"):
            machine.succeed(f"echo 8192 > /sys/block/{disk}/queue/read_ahead_kb")

            machine.succeed(f"udevadm trigger --action=change --settle /sys/block/{disk}")

            assert read_ahead(disk) == "128", f"{disk}'s read-ahead is {read_ahead(disk)!r} KiB after the change event"


    with subtest("it sets both disks' read-ahead again when its unit starts again, as a switch starts it"):
        machine.succeed("echo 8192 > /sys/block/vda/queue/read_ahead_kb")
        machine.succeed("echo 8192 > /sys/block/vdb/queue/read_ahead_kb")

        machine.succeed("systemctl restart disk-read-ahead.service")

        assert read_ahead("vda") == "128", f"vda's read-ahead is {read_ahead('vda')!r} KiB after the unit's start"
        assert read_ahead("vdb") == "128", f"vdb's read-ahead is {read_ahead('vdb')!r} KiB after the unit's start"


    with subtest("it leaves vdc's read-ahead as it is after a change event of vdc"):
        machine.succeed("echo 4096 > /sys/block/vdc/queue/read_ahead_kb")

        machine.succeed("udevadm trigger --action=change --settle /sys/block/vdc")

        assert read_ahead("vdc") == "4096", f"vdc's read-ahead is {read_ahead('vdc')!r} KiB after its change event"


    with subtest("it leaves vdc's read-ahead as it is when its unit starts again"):
        machine.succeed("echo 4096 > /sys/block/vdc/queue/read_ahead_kb")

        machine.succeed("systemctl restart disk-read-ahead.service")

        assert read_ahead("vdc") == "4096", f"vdc's read-ahead is {read_ahead('vdc')!r} KiB after the unit's start"
  '';
}
