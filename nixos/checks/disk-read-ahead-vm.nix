# services.disk-read-ahead on a booted VM with two virtio disks, as geoffcloud has: the module sets
# vda's read-ahead through the kernel's own sysfs, after a device event and after a start of its
# unit, as a switch starts it, and leaves vdb's alone.
# It needs KVM: run `bun run test:nixos disk-read-ahead-vm`.
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
in
pkgs.testers.runNixOSTest {
  name = "disk-read-ahead-vm";
  nodes.machine = {
    imports = [ ../modules/disk-read-ahead.nix ];
    services.disk-read-ahead = {
      enable = true;
      device = "vda";
    };
    # vdb, the second disk
    virtualisation.emptyDiskImages = [ 64 ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target", timeout=300)


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it sets vda's read-ahead at boot"):
        machine.wait_for_unit("disk-read-ahead.service", timeout=60)
        read_ahead = machine.succeed("cat /sys/block/vda/queue/read_ahead_kb").strip()

        assert read_ahead == "128", f"vda's read-ahead is {read_ahead!r} KiB"


    with subtest("it sets vda's read-ahead again after a change event of the disk"):
        machine.succeed("echo 8192 > /sys/block/vda/queue/read_ahead_kb")

        machine.succeed("udevadm trigger --action=change --settle /sys/block/vda")
        read_ahead = machine.succeed("cat /sys/block/vda/queue/read_ahead_kb").strip()

        assert read_ahead == "128", f"vda's read-ahead is {read_ahead!r} KiB after the change event"


    with subtest("it sets vda's read-ahead again when its unit starts again, as a switch starts it"):
        machine.succeed("echo 8192 > /sys/block/vda/queue/read_ahead_kb")

        machine.succeed("systemctl restart disk-read-ahead.service")
        read_ahead = machine.succeed("cat /sys/block/vda/queue/read_ahead_kb").strip()

        assert read_ahead == "128", f"vda's read-ahead is {read_ahead!r} KiB after the unit's start"


    with subtest("it leaves vdb's read-ahead as it is after a change event of vdb"):
        machine.succeed("echo 4096 > /sys/block/vdb/queue/read_ahead_kb")

        machine.succeed("udevadm trigger --action=change --settle /sys/block/vdb")
        read_ahead = machine.succeed("cat /sys/block/vdb/queue/read_ahead_kb").strip()

        assert read_ahead == "4096", f"vdb's read-ahead is {read_ahead!r} KiB after its change event"


    with subtest("it leaves vdb's read-ahead as it is when its unit starts again"):
        machine.succeed("echo 4096 > /sys/block/vdb/queue/read_ahead_kb")

        machine.succeed("systemctl restart disk-read-ahead.service")
        read_ahead = machine.succeed("cat /sys/block/vdb/queue/read_ahead_kb").strip()

        assert read_ahead == "4096", f"vdb's read-ahead is {read_ahead!r} KiB after the unit's start"
  '';
}
