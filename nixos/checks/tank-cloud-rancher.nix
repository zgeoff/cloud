# The move of k3s's data onto the zvol tank/cloud/rancher (docs/runbooks/move-rancher.md) in a NixOS
# VM with geoffcloud's own k3s package and flags, as one journey whose subtests run in order. The
# VM's base config is the one after the move: geoffcloud's /etc/rancher bind, k3s's requiredBy and
# its assertion on /var/lib/rancher/k3s, so the zvol is mounted at /var/lib/rancher. The specialisation `before` is main's config: the zvol
# at /var/lib/tank-cloud/rancher, no bind, and k3s needing the zvol's mount alone. On a pool with
# datasets made by the commands of docs/runbooks/tank-cloud.md and a throwaway key, the journey
# starts a real k3s server on the root disk under `before`, with a pod that writes into a volume
# directory, a Secret, and files with a hard link, an xattr and another owner in that directory.
# It then switches to the base config with switch-to-configuration test as the owner's switch does,
# and checks that k3s stays stopped on the empty zvol. It runs scripts/host/move-rancher.sh copy and
# checks the same cluster CA, node password, Secret and volume on the zvol, runs remove-old, and
# reboots with the pool's disk late, past systemd's default 90 s wait for a device, which the VM
# keeps as geoffcloud does, so k3s starts on the zvol only after the import.
# The pod's image is a local one, as nixpkgs' own k3s test builds it, so the VM pulls nothing. It
# needs KVM: run `bun run test:nixos tank-cloud-rancher`.
{ nixpkgs, geoffcloud }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;
  # 64 hex characters, as keyformat=hex needs; a fixed value, never the host's key
  throwawayKey = lib.strings.replicate 8 "0f1e2d3c";
  hostTank = geoffcloud.config.services.tank-cloud;
  hostK3s = geoffcloud.config.services.k3s;
  moveRancher = ../../scripts/host/move-rancher.sh;
  # one image for the pause container and the pod, loaded from its archive in place of a pull
  image = pkgs.dockerTools.buildLayeredImage {
    name = "test.local/pause";
    tag = "local";
    contents = pkgs.buildEnv {
      name = "tank-cloud-rancher-image-env";
      paths = [
        pkgs.tini
        pkgs.busybox
      ];
    };
    config.Entrypoint = [
      "/bin/tini"
      "--"
      "/bin/sleep"
      "inf"
    ];
  };
  # a volume directory as local-path makes one; the pod appends to a file in it every second, so a
  # copy taken while the pod ran would differ from its old tree
  volume = "/var/lib/rancher/k3s/storage/pvc-0f1e2d3c_fixture_data";
  pod = pkgs.writeText "writer.yaml" ''
    apiVersion: v1
    kind: Pod
    metadata:
      name: writer
      namespace: default
    spec:
      containers:
        - name: writer
          image: test.local/pause:local
          imagePullPolicy: Never
          command: ["sh", "-c", "while true; do date +%s >> /data/ticks; sleep 1; done"]
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          hostPath:
            path: ${volume}
            type: DirectoryOrCreate
  '';
in
pkgs.testers.runNixOSTest {
  name = "tank-cloud-rancher";
  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ ../modules/tank-cloud.nix ];

      options.check.before = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether this is main's config, with the zvol at /var/lib/tank-cloud/rancher.";
      };

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
        # k3s's own binaries and the image on the root disk, then copied
        virtualisation.diskSize = 6144;
        virtualisation.memorySize = 3072;
        virtualisation.cores = 2;
        # geoffcloud waits systemd's default 90 s for a device; a NixOS test VM waits 300 s
        systemd.settings.Manager.DefaultDeviceTimeoutSec = lib.mkForce 90;

        services.tank-cloud = {
          enable = true;
          binds = { inherit (hostTank.binds) etc-rancher; };
          requiredBy = { inherit (hostTank.requiredBy) k3s; };
        };
        # the VM mounts virtualisation.fileSystems in place of fileSystems; main's config mounts the
        # zvol at /var/lib/tank-cloud/rancher with no wait of its own, and binds nothing from it
        virtualisation.fileSystems =
          let
            moved = config.services.tank-cloud.fileSystems;
          in
          if config.check.before then
            removeAttrs moved [
              "/var/lib/rancher"
              "/etc/rancher"
            ]
            // {
              "/var/lib/tank-cloud/rancher" = moved."/var/lib/rancher" // {
                options = [ "nofail" ];
              };
            }
          else
            moved;

        services.k3s = {
          enable = true;
          inherit (hostK3s) package role;
          # geoffcloud's flags, without the components that need images the VM cannot pull
          extraFlags = hostK3s.extraFlags ++ [
            "--disable=coredns"
            "--disable=local-storage"
            "--disable=metrics-server"
            "--pause-image=test.local/pause:local"
          ];
        };
        systemd.services.k3s.unitConfig.AssertPathExists =
          geoffcloud.config.systemd.services.k3s.unitConfig.AssertPathExists;
        environment.etc."k3s-resolv.conf".text = geoffcloud.config.environment.etc."k3s-resolv.conf".text;

        specialisation.before.configuration = {
          check.before = true;
          services.tank-cloud.binds = lib.mkForce { };
          services.tank-cloud.requiredBy = lib.mkForce {
            k3s = [ "rancher" ];
          };
          # main's k3s needed the zvol at its old mount point, and asserted nothing
          systemd.services.k3s.unitConfig = {
            RequiresMountsFor = lib.mkForce [ "/var/lib/tank-cloud/rancher" ];
            AssertPathExists = lib.mkForce [ ];
          };
        };

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
    before = "/run/booted-system/specialisation/before/bin/switch-to-configuration test"
    after = "/run/booted-system/bin/switch-to-configuration test"
    move = "bash -s -- {} < ${moveRancher}"
    volume = "${volume}"
    kubectl = "k3s kubectl"


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
        """what must survive the move: the CA's key pair, the node password, the admin
        kubeconfig, the server token and the Secret, as checksums, never the values"""
        files = [
            "/var/lib/rancher/k3s/server/tls/server-ca.crt",
            "/var/lib/rancher/k3s/server/tls/server-ca.key",
            "/var/lib/rancher/k3s/server/token",
            "/etc/rancher/node/password",
            "/etc/rancher/k3s/k3s.yaml",
        ]
        sums = machine.succeed(f"sha256sum {' '.join(files)}")
        secret = machine.succeed(f"{kubectl} get secret fixture -o jsonpath='{{.data.word}}' | base64 -d").strip()
        return sums, secret


    def wait_for_k3s():
        machine.wait_for_unit("k3s.service")
        machine.wait_until_succeeds(f"{kubectl} get node -o jsonpath='{{.items[0].status.conditions[?(@.type==\"Ready\")].status}}' | grep -x True", timeout=300)


    def wait_for_writer():
        """the pod runs and writes a newer tick into its volume"""
        machine.wait_until_succeeds(f"{kubectl} wait --for condition=Ready pod/writer --timeout=10s", timeout=300)
        last = machine.succeed(f"tail -n 1 {volume}/ticks").strip()
        machine.wait_until_succeeds(f"test \"$(tail -n 1 {volume}/ticks)\" -gt {last}", timeout=60)


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

    with subtest("it starts k3s on the root disk under main's config, with a pod writing into its volume"):
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
        machine.succeed("systemctl start tank-cloud-key.service")
        machine.succeed(before)
        wait_for_k3s()

        assert source("/var/lib/tank-cloud/rancher") == f"{zvol()} ext4"
        assert source("/var/lib/rancher") == ""
        machine.succeed("k3s ctr -n k8s.io images import ${image}")
        machine.wait_until_succeeds(f"{kubectl} get serviceaccount default")
        machine.succeed(f"{kubectl} create secret generic fixture --from-literal=word=kept-across-the-move")
        machine.succeed(f"{kubectl} apply -f ${pod}")
        wait_for_writer()
        # what cp -a must keep: a hard link, an xattr in the trusted namespace, an ACL, and an owner
        # that is not root
        machine.succeed(f"echo linked > {volume}/one && ln {volume}/one {volume}/two")
        machine.succeed(f"setfattr -n trusted.fixture -v kept {volume}/one")
        machine.succeed(f"echo acl > {volume}/acl && setfacl -m u:65534:r {volume}/acl")
        machine.succeed(f"echo owned > {volume}/owned && chown 1234:5678 {volume}/owned && chmod 0640 {volume}/owned")
        # and the root's own xattr and mode, which the zvol's root takes from the staging copy
        machine.succeed("setfattr -n user.fixture -v root-kept /var/lib/rancher && chmod 0750 /var/lib/rancher")
        before_move = cluster()


    with subtest("it keeps k3s stopped on the empty zvol after the switch, before the copy"):
        status, output = machine.execute(f"{after} 2>&1")
        machine.log(output)

        # a failed assertion fails no unit, so the switch passes, as the owner's switch does before
        # its nixie readiness check
        assert status == 0, f"the switch exited {status}"
        assert "Assertion failed for k3s service." in machine.succeed("journalctl -b -u k3s.service --no-pager")
        assert_no_ordering_cycle()
        assert source("/var/lib/rancher") == f"{zvol()} ext4"
        # systemd makes the bind's missing source directory, empty, on the zvol
        assert source("/etc/rancher") == f"{zvol()}[/etc-rancher] ext4"
        assert machine.succeed("ls -A /var/lib/rancher").split() == ["etc-rancher", "lost+found"]
        assert machine.succeed("ls -A /etc/rancher") == ""
        state = machine.succeed("systemctl show -p ActiveState,AssertResult --value k3s.service").split()
        assert state == ["inactive", "no"], f"k3s is {state}"
        # k3s's containers outlive it: the pod still writes into its volume on the root disk
        machine.succeed("pgrep -f containerd-shim")
        assert root_disk("/var/lib/rancher") == ["k3s"]


    with subtest("it refuses to remove the old copy while the zvol holds no cluster CA"):
        status, output = machine.execute(move.format("remove-old") + " 2>&1")

        assert status == 1, f"remove-old exited {status}"
        assert output == "move-rancher: refusing to remove: the zvol holds no cluster CA\n", output
        assert root_disk("/var/lib/rancher") == ["k3s"]


    with subtest("it refuses to copy onto a sparse zvol"):
        machine.succeed("zfs set refreservation=none tank/cloud/rancher")
        status, output = machine.execute(move.format("copy") + " 2>&1")
        machine.succeed("zfs set refreservation=auto tank/cloud/rancher")

        assert status == 1, f"copy exited {status}"
        assert output.startswith("move-rancher: refusing to copy: tank/cloud/rancher is sparse (refreservation 0 < volsize "), output
        machine.succeed("pgrep -f containerd-shim")


    with subtest("it copies k3s's data onto the zvol, stops the pod first, and starts k3s on the same cluster"):
        copied = machine.succeed(move.format("copy"))
        machine.log(copied)
        lines = copied.splitlines()

        assert lines[0].startswith("stopped k3s: killed "), copied
        assert int(lines[0].split()[3]) > 0, copied
        assert lines[1].startswith("unmounted "), copied
        assert lines[2].startswith("copied /var/lib/rancher and /etc/rancher: "), copied
        assert lines[3].startswith("match /var/lib/rancher: "), copied
        assert lines[4].startswith("match /etc/rancher: "), copied
        assert lines[5:] == ["started k3s on tank/cloud/rancher"], copied
        assert source("/var/lib/rancher") == f"{zvol()} ext4"
        assert source("/etc/rancher") == f"{zvol()}[/etc-rancher] ext4"
        wait_for_k3s()
        assert cluster() == before_move
        wait_for_writer()
        assert machine.succeed(f"stat -c '%h %i' {volume}/one").split()[0] == "2"
        assert machine.succeed(f"stat -c %i {volume}/one") == machine.succeed(f"stat -c %i {volume}/two")
        assert machine.succeed(f"getfattr --only-values -n trusted.fixture {volume}/one") == "kept"
        assert "user:65534:r--" in machine.succeed(f"getfacl -n -p {volume}/acl")
        assert machine.succeed(f"stat -c '%u:%g %a' {volume}/owned").strip() == "1234:5678 640"
        assert machine.succeed("getfattr --only-values -n user.fixture /var/lib/rancher") == "root-kept"
        assert machine.succeed("stat -c %a /var/lib/rancher").strip() == "750"


    with subtest("it refuses a second copy once k3s has run on the zvol"):
        status, output = machine.execute(move.format("copy") + " 2>&1")

        assert status == 1, f"copy exited {status}"
        assert output == "move-rancher: refusing to copy: /var/lib/rancher/k3s exists on the zvol, so the copy is done and k3s may have run on it\n", output
        machine.succeed("systemctl is-active k3s.service")


    with subtest("it removes the old copy from the root disk, and keeps the cluster on the zvol"):
        removed = machine.succeed(move.format("remove-old"))
        lines = removed.splitlines()

        assert len(lines) == 3, removed
        assert lines[0].startswith("removed /var/lib/rancher: ") and lines[1].startswith("removed /etc/rancher: "), removed
        # main's mount point, empty on the root disk once the switch unmounted the zvol there
        assert lines[2] == "removed /var/lib/tank-cloud/rancher", removed
        assert root_disk("/var/lib/rancher") == []
        assert root_disk("/etc/rancher") == []
        assert cluster() == before_move
        machine.succeed("systemctl is-active k3s.service")


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
        assert cluster() == before_move
        wait_for_writer()
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units failed at boot: {failed}"
        assert root_disk("/var/lib/rancher") == []
        assert root_disk("/etc/rancher") == []
  '';
}
