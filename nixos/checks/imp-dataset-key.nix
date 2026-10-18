# The boot unlock of tank/imp (modules/imp-dataset-key.nix) in a NixOS VM under imp's own module,
# as one journey whose subtests run in order. On a pool shaped like geoffcloud's, the VM first boots
# with no tank/imp, then makes tank/imp as its own encryption root, keyed by tank/cloud's key file
# as docs/runbooks/tank-imp-encryption.md left it, with files in place of impd's database and
# secrets. It reboots into the encrypted dataset with its key, then without it, then restores the
# key. The stand-in imp-host is busybox that only sleeps (build-stub-imp-host-image.nix), loaded
# from its archive in place of a pull. The test utilities pass their own check
# (test-utils-check.nix) before the VM runs. It needs KVM: run `bun run test:nixos imp-dataset-key`.
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;
  # 64 hex characters, as keyformat=hex needs; a fixed value, never the host's key
  throwawayKey = lib.strings.replicate 8 "0f1e2d3c";
  image = import ./test-utils/build-stub-imp-host-image.nix { inherit pkgs; } "2.1.0";
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
in
pkgs.testers.runNixOSTest {
  name = "imp-dataset-key";
  nodes.machine =
    { config, ... }:
    {
      imports = [
        imp.nixosModules.imp
        ../modules/imp-dataset-key.nix
      ];
      networking.hostId = "5ca71846";
      # the VM reaches nothing, and dhcpcd crashing at times would fail a unit at boot
      networking.useDHCP = false;
      # imp-host's docker run passes --device /dev/kvm
      boot.kernelModules = [
        "kvm-amd"
        "kvm-intel"
      ];
      # as geoffcloud, where modules/tank-cloud.nix turns it off: the pool's import loads no key
      boot.zfs.requestEncryptionCredentials = false;
      virtualisation.emptyDiskImages = [ 4096 ];
      virtualisation.memorySize = 2048;

      services.imp = {
        enable = true;
        image = "ghcr.io/zgeoff/imp-host:2.1.0";
        imageArchive = image.archive;
        zfs.arcMaxMiB = 64;
        ramBudgetMiB = 512;
      };
      services.imp-dataset-key.enable = true;

      # the pool, made once on the empty disk before its first import, with geoffcloud's
      # properties on tank; zpool create leaves a partition table, so a later boot only imports it
      systemd.services.rehearsal-pool = {
        requiredBy = [ "zfs-import-tank.service" ];
        before = [ "zfs-import-tank.service" ];
        requires = [ "dev-vdb.device" ];
        after = [ "dev-vdb.device" ];
        unitConfig.DefaultDependencies = false;
        path = [
          config.boot.zfs.package
          pkgs.util-linux
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if [ -z "$(blkid -o value -s PTTYPE /dev/vdb || true)" ]; then
            zpool create -O mountpoint=none -O compression=lz4 -O atime=off -O xattr=sa tank /dev/vdb
          fi
        '';
      };
    };

  testScript = ''
    # the shared test utilities pass their own tests before any subtest relies on them:
    # ${testUtilsCheck}
    key = "${throwawayKey}"
    key_url = "file:///var/lib/zfs-keys/tank.key"


    def file_sums():
        """tank/imp's files and their sha256, through a read-only mount"""
        machine.succeed("mkdir -p /mnt/sums && mount -t zfs -o ro tank/imp /mnt/sums")
        sums = machine.succeed("cd /mnt/sums && find . -type f -print0 | sort -z | xargs -0r sha256sum")
        machine.succeed("umount /mnt/sums")
        return sums


    def assert_imp_host_held(reason):
        """imp-dataset-key failed for reason, and neither imp's dataset unit nor imp-host ran"""
        machine.wait_until_succeeds("test \"$(systemctl show -p ActiveState --value imp-dataset-key)\" = failed")
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend --full | cut -d' ' -f1").split()
        assert failed == ["imp-dataset-key.service"], f"the failed units are {failed}"
        key_log = machine.succeed("journalctl -b -u imp-dataset-key.service --no-pager")
        assert reason in key_log, key_log
        states = machine.succeed("systemctl show -p ActiveState --value imp-zfs-dataset imp-host").split()
        assert states == ["inactive", "inactive"], f"the units are {states}"


    machine.wait_for_unit("multi-user.target")


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it keeps imp-host stopped and makes no plain tank/imp when imp-dataset-key finds none"):
        assert_imp_host_held("imp-dataset-key: tank/imp is missing; imp's module would make a plain one")

        machine.fail("zfs list tank/imp")


    with subtest("it starts imp-host on tank/imp once tank/imp is its own encryption root"):
        machine.succeed("install -d -m 0700 /var/lib/zfs-keys")
        machine.succeed(f"printf '%s' {key} > /var/lib/zfs-keys/tank.key && chmod 0400 /var/lib/zfs-keys/tank.key")
        machine.succeed(f"zfs create -o encryption=aes-256-gcm -o keyformat=hex -o keylocation={key_url} -o mountpoint=legacy tank/imp")
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db /mnt/imp/secrets /mnt/imp/tls")
        for path in ["db/imp.sqlite", "secrets/root-token", "tls/key.pem"]:
            machine.succeed(f"head -c 64 /dev/urandom | base64 > /mnt/imp/{path} && chmod 0600 /mnt/imp/{path}")
        machine.succeed("umount /mnt/imp")
        machine.succeed("systemctl reset-failed")

        machine.succeed("systemctl start imp-host")

        machine.wait_for_unit("imp-host.service")
        status = machine.succeed("zfs get -H -o value encryptionroot,keystatus tank/imp").split()
        assert status == ["tank/imp", "available"], f"tank/imp is {status}"


    with subtest("it loads tank/imp's key at boot, and starts imp-host on the same files"):
        sums = file_sums()
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("imp-host.service")

        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units failed at boot: {failed}"
        status = machine.succeed("zfs get -H -o value encryptionroot,keystatus tank/imp").split()
        assert status == ["tank/imp", "available"], f"tank/imp is {status}"
        machine.succeed("systemctl is-active imp-dataset-key")
        assert file_sums() == sums, "the files changed across the reboot"


    with subtest("without the key file, it boots to SSH with imp-host stopped, and makes no plain tank/imp"):
        machine.succeed("rm /var/lib/zfs-keys/tank.key")
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")

        assert_imp_host_held("Failed to open key material file")
        status = machine.succeed("zfs get -H -o value encryptionroot,keystatus tank/imp").split()
        assert status == ["tank/imp", "unavailable"], f"tank/imp is {status}"


    with subtest("it starts imp-host once the key is back"):
        machine.succeed(f"printf '%s' {key} > /var/lib/zfs-keys/tank.key && chmod 0400 /var/lib/zfs-keys/tank.key")

        machine.succeed("systemctl start imp-host")

        machine.wait_for_unit("imp-host.service")
        status = machine.succeed("zfs get -H -o value keystatus tank/imp").strip()
        assert status == "available", f"the key is {status}"
  '';
}
