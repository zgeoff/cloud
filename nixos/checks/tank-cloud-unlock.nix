# The boot unlock of tank/cloud (modules/tank-cloud.nix) in a NixOS VM, across real reboots: a
# ZFS pool on an empty disk, imported at boot as geoffcloud imports tank, and the datasets made
# with the commands of docs/runbooks/tank-cloud.md and a throwaway key, and the bind mounts of
# geoffcloud's own services.tank-cloud.binds on directories made on the datasets, as the move of
# the host secrets makes them (docs/runbooks/move-host-secrets.md). A stand-in for each service in
# geoffcloud's own services.tank-cloud.requiredBy needs the datasets and binds that it names, and
# writes a marker into every one of them when it starts, so a start on the root disk's empty mount
# points would leave a file there. The subtests are one journey and run in order: datasets made, a
# reboot that mounts them and the binds, a reboot with the key file gone, and the key restored
# without a trailing newline, as `op read --no-newline` writes it.
# It needs KVM: run `bun run test:nixos tank-cloud-unlock`.
{ nixpkgs, geoffcloud }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;
  # 64 hex characters, as keyformat=hex needs; a fixed value, never the host's key
  throwawayKey = lib.strings.replicate 8 "0f1e2d3c";
  requiredBy = geoffcloud.config.services.tank-cloud.requiredBy;
  binds = geoffcloud.config.services.tank-cloud.binds;
  mountPoint =
    dataset: if dataset == "rancher" then "/var/lib/rancher" else "/var/lib/tank-cloud/${dataset}";
  # a requiredBy name is a dataset or a bind; either gives the path to write into
  pathOf = name: if binds ? ${name} then binds.${name}.path else mountPoint name;
  bindPaths = lib.mapAttrsToList (_: bind: bind.path) binds;
in
pkgs.testers.runNixOSTest {
  name = "tank-cloud-unlock";
  nodes.machine =
    { config, ... }:
    {
      imports = [ ../modules/tank-cloud.nix ];
      networking.hostId = "5ca71846";
      # the VM reaches nothing, and dhcpcd crashing at times would fail a unit at boot
      networking.useDHCP = false;
      boot.supportedFilesystems = [ "zfs" ];
      boot.zfs.forceImportRoot = false;
      boot.zfs.extraPools = [ "tank" ];
      # as geoffcloud: a virtio disk has no serial, so no /dev/disk/by-id link
      boot.zfs.devNodes = "/dev/disk/by-partuuid";
      virtualisation.emptyDiskImages = [ 2048 ];
      # half of a restore rehearsal's, so it and a rehearsal fit the runner side by side
      virtualisation.memorySize = 1024;
      services.openssh.enable = true;

      services.tank-cloud = {
        enable = true;
        inherit binds requiredBy;
      };
      # the VM mounts virtualisation.fileSystems in place of fileSystems
      virtualisation.fileSystems = config.services.tank-cloud.fileSystems;

      systemd.services = {
        # the pool, made once on the empty disk before its first import; zpool create leaves a
        # partition table, so a later boot finds one and only imports the pool
        check-pool = {
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
              zpool create -O mountpoint=none tank /dev/vdb
            fi
          '';
        };
      }
      // lib.mapAttrs (name: needed: {
        description = "stand-in ${name}";
        wantedBy = [ "multi-user.target" ];
        script = ''
          for path in ${lib.escapeShellArgs (map pathOf needed)}; do
            echo started > "$path/${name}-started"
          done
          exec sleep infinity
        '';
      }) requiredBy;
    };

  testScript = ''
    key = "${throwawayKey}"
    services = ${builtins.toJSON (lib.attrNames requiredBy)}
    mount_points = ["${mountPoint "host-secrets"}", "${mountPoint "imp-db-backups"}", "${mountPoint "rancher"}"]
    bind_paths = ${builtins.toJSON bindPaths}


    def bind_mounts(zvol):
        """each bind's source, in the order of bind_paths"""
        return [
            "tank/cloud/host-secrets[/atc-daemon] zfs",
            f"{zvol}[/etc-rancher] ext4",
            "tank/cloud/host-secrets[/imp-host] zfs",
            "tank/cloud/imp-db-backups zfs",
        ]


    def assert_unlocked():
        status = machine.succeed("zfs get -H -o value encryption,keyformat,keylocation,keystatus tank/cloud").split()
        assert status == ["aes-256-gcm", "hex", "file:///var/lib/zfs-keys/tank.key", "available"], f"tank/cloud is {status}"
        zvol = machine.succeed("readlink -f /dev/zvol/tank/cloud/rancher").strip()
        mounts = [machine.succeed(f"findmnt -rn -o SOURCE,FSTYPE --mountpoint {path}").strip() for path in mount_points]
        assert mounts == ["tank/cloud/host-secrets zfs", "tank/cloud/imp-db-backups zfs", f"{zvol} ext4"], f"the mounts are {mounts}"
        binds = [machine.succeed(f"findmnt -rn -o SOURCE,FSTYPE --mountpoint {path}").strip() for path in bind_paths]
        assert binds == bind_mounts(zvol), f"the binds are {binds}"


    def assert_no_ordering_cycle():
        """systemd breaks an ordering cycle by deleting one of its jobs, and which one can differ
        from boot to boot, so a cycle fails a unit only at times: the journal names every one"""
        cycles = machine.succeed("journalctl -b -q --no-pager --grep 'ordering cycle' || true").strip()
        assert cycles == "", f"the boot has an ordering cycle: {cycles}"


    machine.wait_for_unit("multi-user.target")


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"
        assert_no_ordering_cycle()


    # with no datasets yet, the rancher mount's wait for its device is still queued; cancel it, so
    # the zvol that zfs create makes does not start an fsck under mkfs. On geoffcloud the commands
    # run before the switch, so no unit waits for the device then.
    machine.succeed("systemctl cancel")

    # the runbook's commands, in its order, with the key file written as op read --no-newline
    # writes it: 64 characters and no newline
    machine.succeed("install -d -m 0700 /var/lib/zfs-keys")
    machine.succeed(f"printf '%s' {key} > /var/lib/zfs-keys/tank.key")
    machine.succeed("chmod 0400 /var/lib/zfs-keys/tank.key")
    machine.succeed("test \"$(wc -c < /var/lib/zfs-keys/tank.key)\" -eq 64")
    machine.succeed(
        "zfs create -o encryption=aes-256-gcm -o keyformat=hex"
        " -o keylocation=file:///var/lib/zfs-keys/tank.key -o compression=lz4 -o mountpoint=legacy tank/cloud"
    )
    machine.succeed("zfs create -o mountpoint=legacy tank/cloud/host-secrets")
    machine.succeed("zfs create -o mountpoint=legacy tank/cloud/imp-db-backups")
    machine.succeed("zfs create -s -V 64G tank/cloud/rancher")
    machine.succeed("udevadm settle")
    machine.succeed("mkfs.ext4 -q -L rancher /dev/zvol/tank/cloud/rancher")
    # the directories the binds mount, made on the datasets as the move's seed step makes them; the
    # datasets are mounted for this, and the next boot mounts them again
    machine.succeed("systemctl start tank-cloud-key.service")
    for dataset in ["host-secrets", "imp-db-backups"]:
        machine.succeed(f"install -d /var/lib/tank-cloud/{dataset} && mount /var/lib/tank-cloud/{dataset}")
    machine.succeed("install -d -m 0700 /var/lib/tank-cloud/host-secrets/imp-host /var/lib/tank-cloud/host-secrets/atc-daemon")
    machine.succeed("umount /var/lib/tank-cloud/host-secrets /var/lib/tank-cloud/imp-db-backups")
    # the bind paths on the root disk, empty, as they stay once the move has removed the old copies
    machine.succeed(f"install -d -m 0700 {' '.join(bind_paths)}")


    with subtest("it unlocks and mounts every tank/cloud dataset at boot, and starts the services that need them"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        assert_no_ordering_cycle()
        for service in services:
            machine.wait_for_unit(f"{service}.service")

        assert_unlocked()
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units failed at boot: {failed}"
        # data the restored key must find again
        for path in mount_points:
            machine.succeed(f"echo before-the-key-was-lost > {path}/data")
        listing = {path: machine.succeed(f"ls -A {path}").split() for path in mount_points + bind_paths}
        assert listing == {
            "${mountPoint "host-secrets"}": ["atc-daemon", "data", "imp-host", "imp-host-started", "preview-started"],
            "${mountPoint "imp-db-backups"}": ["data"],
            "${mountPoint "rancher"}": ["data", "etc-rancher", "k3s-started", "lost+found"],
            "/var/lib/atc-daemon-secrets": ["atc-daemon-started"],
            "/etc/rancher": ["k3s-started"],
            "/var/lib/imp-host/secrets": ["imp-host-dns-token-started", "imp-host-started"],
            "/root/imp-db-backups": ["data"],
        }, f"the datasets hold {listing}"


    with subtest("with the key file gone, it boots to multi-user with sshd running, and keeps the services that need tank/cloud stopped"):
        machine.succeed("rm /var/lib/zfs-keys/tank.key")
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        assert_no_ordering_cycle()
        machine.wait_for_unit("sshd.service")
        machine.wait_for_open_port(22)

        _, state = machine.execute("systemctl is-system-running --wait")
        assert state.strip() == "degraded", f"the system is {state.strip()!r}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend --full | cut -d' ' -f1").split()
        assert failed == ["tank-cloud-key.service"], f"the failed units are {failed}"
        key_log = machine.succeed("journalctl -b -u tank-cloud-key.service --no-pager")
        assert "Failed to open key material file" in key_log, key_log
        keystatus = machine.succeed("zfs get -H -o value keystatus tank/cloud").strip()
        assert keystatus == "unavailable", f"the key is {keystatus}"
        states = machine.succeed(f"systemctl show -p ActiveState --value {' '.join(services)}").split()
        assert states == ["inactive"] * len(services), f"the services are {states}"
        for path in mount_points + bind_paths:
            machine.fail(f"mountpoint -q {path}")
        # the bind paths and k3s's data directory on the root disk stay empty: nothing wrote into them
        for path in bind_paths + ["${mountPoint "rancher"}"]:
            left = machine.succeed(f"ls -A {path}")
            assert left == "", f"{path} on the root disk holds {left!r}"
        # the empty mount points on the root disk, and nothing under them
        left = machine.succeed("find /var/lib/tank-cloud -mindepth 1 | sort").split()
        assert left == mount_points[:2], f"the root disk holds {left}"


    with subtest("it loads a key restored without a trailing newline when tank-cloud.target and the services start again"):
        machine.succeed(f"printf '%s' {key} > /var/lib/zfs-keys/tank.key")
        machine.succeed("chmod 0400 /var/lib/zfs-keys/tank.key")
        machine.succeed("test \"$(wc -c < /var/lib/zfs-keys/tank.key)\" -eq 64")

        machine.succeed(f"systemctl start tank-cloud.target {' '.join(services)}")

        assert_unlocked()
        states = machine.succeed(f"systemctl show -p ActiveState --value {' '.join(services)}").split()
        assert states == ["active"] * len(services), f"the services are {states}"
        data = [machine.succeed(f"cat {path}/data").strip() for path in mount_points]
        assert data == ["before-the-key-was-lost"] * 3, f"the datasets hold {data}"
  '';
}
