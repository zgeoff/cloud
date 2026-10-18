# k3s on the zvol tank/cloud/rancher in a NixOS VM with geoffcloud's own k3s package and flags, as
# one journey whose subtests run in order. The VM's config is geoffcloud's layout: the zvol mounted
# at /var/lib/rancher, its directory etc-rancher bound at /etc/rancher, k3s's requiredBy, and k3s's
# assertion on the cluster's server data. On a pool with datasets made by the commands of
# docs/runbooks/tank-cloud.md and a throwaway key, the journey checks that k3s stays stopped on the
# empty zvol, on the binaries a k3s command unpacks there and on empty server directories. It then
# starts a first k3s server with the assertion lifted for that start alone, checks that the
# cluster's CA and datastore pass the assertion, and reboots with the pool's disk late, past
# systemd's default 90 s wait for a device, which the VM keeps as geoffcloud does, so k3s starts on
# the same cluster on the zvol only after the import. It needs KVM: run
# `bun run test:nixos tank-cloud-rancher`.
{ nixpkgs, geoffcloud }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;
  # 64 hex characters, as keyformat=hex needs; a fixed value, never the host's key
  throwawayKey = lib.strings.replicate 8 "0f1e2d3c";
  hostTank = geoffcloud.config.services.tank-cloud;
  hostK3s = geoffcloud.config.services.k3s;
in
pkgs.testers.runNixOSTest {
  name = "tank-cloud-rancher";
  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ ../modules/tank-cloud.nix ];

      config = {
        networking.hostId = "5ca71846";
        # the VM reaches nothing, and dhcpcd crashing at times would fail a unit at boot
        networking.useDHCP = false;
        # k3s refuses to start without a default route; nothing answers at the gateway
        networking.defaultGateway = {
          address = "192.168.1.254";
          interface = "eth1";
        };
        boot.supportedFilesystems = [ "zfs" ];
        boot.zfs.forceImportRoot = false;
        boot.zfs.extraPools = [ "tank" ];
        # as geoffcloud: a virtio disk has no serial, so no /dev/disk/by-id link
        boot.zfs.devNodes = "/dev/disk/by-partuuid";
        virtualisation.emptyDiskImages = [ 6144 ];
        virtualisation.memorySize = 3072;
        virtualisation.cores = 2;
        # geoffcloud waits systemd's default 90 s for a device; a NixOS test VM waits 300 s
        systemd.settings.Manager.DefaultDeviceTimeoutSec = lib.mkForce 90;

        services.tank-cloud = {
          enable = true;
          binds = { inherit (hostTank.binds) etc-rancher; };
          requiredBy = { inherit (hostTank.requiredBy) k3s; };
        };
        # the VM mounts virtualisation.fileSystems in place of fileSystems
        virtualisation.fileSystems = config.services.tank-cloud.fileSystems;

        services.k3s = {
          enable = true;
          inherit (hostK3s) package role;
          # geoffcloud's flags, without the components that need images the VM cannot pull
          extraFlags = hostK3s.extraFlags ++ [
            "--disable=coredns"
            "--disable=local-storage"
            "--disable=metrics-server"
          ];
        };
        systemd.services.k3s.unitConfig.AssertPathExists =
          geoffcloud.config.systemd.services.k3s.unitConfig.AssertPathExists;
        environment.etc."k3s-resolv.conf".text = geoffcloud.config.environment.etc."k3s-resolv.conf".text;

        # the pool, made once on the empty disk before its first import; zpool create leaves a
        # partition table, so a later boot finds one and only imports the pool. While
        # /var/lib/slow-vdb exists, it holds the import back for longer than systemd's default
        # 90 s wait for a device, as a slow vdb would.
        systemd.services.check-pool = {
          requiredBy = [ "zfs-import-tank.service" ];
          before = [ "zfs-import-tank.service" ];
          requires = [ "dev-vdb.device" ];
          after = [ "dev-vdb.device" ];
          unitConfig.DefaultDependencies = false;
          path = [
            config.boot.zfs.package
            pkgs.util-linux
            pkgs.coreutils
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            if [ -e /var/lib/slow-vdb ]; then
              sleep 100
            fi
            if [ -z "$(blkid -o value -s PTTYPE /dev/vdb || true)" ]; then
              zpool create -O mountpoint=none -O compression=lz4 -O atime=off -O xattr=sa tank /dev/vdb
            fi
          '';
        };
      };
    };

  testScript = ''
    key = "${throwawayKey}"
    kubectl = "k3s kubectl"
    # a runtime drop-in that empties the unit's AssertPathExists= list, for the first start alone
    first_start = "/run/systemd/system/k3s.service.d/first-start.conf"


    def assert_no_ordering_cycle():
        """systemd breaks an ordering cycle by deleting one of its jobs, and which one can differ
        from boot to boot, so a cycle fails a unit only at times: the journal names every one"""
        cycles = machine.succeed("journalctl -b -q --no-pager --grep 'ordering cycle' || true").strip()
        assert cycles == "", f"the boot has an ordering cycle: {cycles}"


    def zvol():
        return machine.succeed("readlink -f /dev/zvol/tank/cloud/rancher").strip()


    def source(path):
        return machine.succeed(f"findmnt -rn -o SOURCE,FSTYPE --mountpoint {path} || true").strip()


    def cluster():
        """what a reboot must keep: the CA's key pair, the node password, the admin kubeconfig,
        the server token and a Secret, as checksums, never the values"""
        files = [
            "/var/lib/rancher/k3s/server/tls/server-ca.crt",
            "/var/lib/rancher/k3s/server/tls/server-ca.key",
            "/var/lib/rancher/k3s/server/token",
            "/etc/rancher/node/password",
            "/etc/rancher/k3s/k3s.yaml",
        ]
        sums = machine.succeed(f"sha256sum {' '.join(files)}")
        # k3s can stop itself just after a boot, when the netlink dump of the links is interrupted
        # ("results may be incomplete or inconsistent"), and systemd starts it again
        secret = machine.wait_until_succeeds(f"{kubectl} get secret fixture -o jsonpath='{{.data.word}}' | base64 -d", timeout=300).strip()
        return sums, secret


    def wait_for_k3s():
        machine.wait_for_unit("k3s.service")
        machine.wait_until_succeeds(f"{kubectl} get node -o jsonpath='{{.items[0].status.conditions[?(@.type==\"Ready\")].status}}' | grep -x True", timeout=300)


    def assert_start_refused():
        status, output = machine.execute("systemctl start k3s.service 2>&1")
        assert status == 1 and output == "Assertion failed on job for k3s.service.\n", f"start exited {status}: {output}"
        state = machine.succeed("systemctl show -p ActiveState,AssertResult --value k3s.service").split()
        assert state == ["inactive", "no"], f"k3s is {state}"


    def root_disk(path):
        """the entries of a path on the root disk, seen without the mounts above it"""
        machine.succeed("mkdir -p /mnt/root-disk && mount --bind / /mnt/root-disk")
        entries = machine.succeed(f"ls -A /mnt/root-disk{path}").split()
        machine.succeed("umount /mnt/root-disk")
        return entries


    machine.wait_for_unit("multi-user.target")


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"
        assert_no_ordering_cycle()


    # with no datasets yet, the rancher mount's wait for its device is still queued; cancel it, so
    # the zvol that zfs create makes does not start an fsck under mkfs
    machine.succeed("systemctl cancel")

    with subtest("it mounts the empty zvol and its bind, and keeps k3s stopped on them"):
        machine.succeed("install -d -m 0700 /var/lib/zfs-keys")
        machine.succeed(f"printf '%s' {key} > /var/lib/zfs-keys/tank.key")
        machine.succeed("chmod 0400 /var/lib/zfs-keys/tank.key")
        machine.succeed(
            "zfs create -o encryption=aes-256-gcm -o keyformat=hex"
            " -o keylocation=file:///var/lib/zfs-keys/tank.key -o compression=lz4 -o mountpoint=legacy tank/cloud"
        )
        machine.succeed("zfs create -o mountpoint=legacy tank/cloud/host-secrets")
        machine.succeed("zfs create -o mountpoint=legacy tank/cloud/imp-db-backups")
        # fully reserved, as the runbook makes it, and smaller, to fit the VM's pool
        machine.succeed("zfs create -V 3G tank/cloud/rancher")
        machine.succeed("udevadm settle")
        machine.succeed("mkfs.ext4 -q -L rancher /dev/zvol/tank/cloud/rancher")
        machine.succeed("systemctl start tank-cloud.target")

        assert source("/var/lib/rancher") == f"{zvol()} ext4"
        # systemd makes the bind's missing source directory, empty, on the zvol
        assert source("/etc/rancher") == f"{zvol()}[/etc-rancher] ext4"
        assert machine.succeed("ls -A /var/lib/rancher").split() == ["etc-rancher", "lost+found"]
        assert machine.succeed("ls -A /etc/rancher") == ""
        # the guard is geoffcloud's own, from its evaluated config
        guard = machine.succeed("grep '^Assert' /etc/systemd/system/k3s.service")
        assert guard == (
            "AssertPathExists=/var/lib/rancher/k3s/server/tls/server-ca.crt\n"
            "AssertPathExists=/var/lib/rancher/k3s/server/db/state.db\n"
        ), guard
        assert_start_refused()


    with subtest("it unpacks k3s's binaries onto the zvol for any k3s command, with no cluster"):
        machine.succeed(f"{kubectl} version --client")

        assert machine.succeed("ls -A /var/lib/rancher/k3s").split() == ["data"]
        assert machine.succeed("systemctl is-active k3s.service || true").strip() == "inactive"


    with subtest("it fails k3s's start on the unpacked binaries alone, and on empty server directories"):
        assert_start_refused()
        assert machine.succeed("ls -A /var/lib/rancher/k3s").split() == ["data"]

        # the directories that would hold the CA and the datastore, without the files
        machine.succeed("mkdir -p /var/lib/rancher/k3s/server/tls /var/lib/rancher/k3s/server/db")
        assert_start_refused()
        machine.succeed("rm -r /var/lib/rancher/k3s/server")
        assert machine.succeed("ls -A /var/lib/rancher/k3s").split() == ["data"]


    with subtest("it starts k3s on the zvol once the cluster's CA and datastore exist there"):
        # the first start makes the cluster, with the guard lifted for it alone
        machine.succeed(f"mkdir -p {first_start.rsplit('/', 1)[0]} && printf '[Unit]\\nAssertPathExists=\\n' > {first_start}")
        machine.succeed("systemctl daemon-reload && systemctl start k3s.service")
        wait_for_k3s()
        machine.wait_until_succeeds(f"{kubectl} get serviceaccount default")
        machine.succeed(f"{kubectl} create secret generic fixture --from-literal=word=kept-across-the-reboot")
        machine.succeed(f"rm {first_start} && systemctl daemon-reload")

        machine.succeed("systemctl restart k3s.service")

        assert machine.succeed("systemctl show -p AssertResult --value k3s.service").strip() == "yes"
        wait_for_k3s()
        first_cluster = cluster()


    with subtest("it starts k3s on the zvol after a reboot whose pool import waits longer than a device's default timeout"):
        machine.succeed("touch /var/lib/slow-vdb")
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        assert_no_ordering_cycle()
        wait_for_k3s()

        def entered(unit):
            return int(machine.succeed(f"systemctl show -p ActiveEnterTimestampMonotonic --value {unit}").strip())

        order = [
            entered("zfs-import-tank.service"),
            entered("tank-cloud-key.service"),
            entered("var-lib-rancher.mount"),
            entered("etc-rancher.mount"),
            int(machine.succeed("systemctl show -p ExecMainStartTimestampMonotonic --value k3s.service").strip()),
        ]
        assert order == sorted(order), f"the units started in the order {order}"
        assert order[0] > 90_000_000, f"the import finished {order[0]} us after the boot, before the default device timeout"
        timeouts = machine.succeed("systemctl show -p JobRunningTimeoutUSec --value dev-zvol-tank-cloud-rancher.device dev-vda.device").split("\n\n")
        assert [t.strip() for t in timeouts] == ["5min", "1min 30s"], f"the devices wait {timeouts}"
        assert source("/var/lib/rancher") == f"{zvol()} ext4"
        assert source("/etc/rancher") == f"{zvol()}[/etc-rancher] ext4"
        assert cluster() == first_cluster
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units failed at boot: {failed}"
        # k3s never wrote under the empty mount points on the root disk
        assert root_disk("/var/lib/rancher") == []
        assert root_disk("/etc/rancher") == []
  '';
}
