# geoffcloud's host secrets and impd's database copies on tank/cloud in a NixOS VM under imp's own
# module and the real atc daemon module, as one journey whose subtests run in order. The VM's config
# has services.tank-cloud with geoffcloud's own binds and requiredBy, and the host's dependency of
# the DNS token path unit on the secrets directory. On a pool with datasets made by the commands of
# docs/runbooks/tank-cloud.md and a throwaway key, the journey puts fake secrets in geoffcloud's
# shapes on the datasets, starts the services, and checks the mounts, the staged secrets, the
# daemon's credential, and the copy of the gateway token that the daemon serves on. Then it takes an impd database copy with copy-impd-db-host, runs the install
# scripts' host halves against the binds, and reboots. A stand-in k3s needs the rancher mount, as
# geoffcloud's k3s does. The atc daemon is the real service module with the pinned atc release; the
# imp-host image is the stand-in busybox one (test-utils/build-stub-imp-host-image.nix), loaded from
# its archive in place of a pull. The test utilities pass their own check (test-utils-check.nix)
# before the VM runs. It needs KVM: run `bun run test:nixos tank-cloud-host-secrets`.
{
  nixpkgs,
  imp,
  geoffcloud,
}:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;
  # 64 hex characters, as keyformat=hex needs; a fixed value, never the host's key
  throwawayKey = lib.strings.replicate 8 "0f1e2d3c";
  image = import ./test-utils/build-stub-imp-host-image.nix { inherit pkgs; } "2.1.0";
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  impdDbTools = pkgs.callPackage ../packages/impd-db-tools { };
  atc = pkgs.callPackage ../packages/atc.nix { };
  hostTank = geoffcloud.config.services.tank-cloud;
  hostImp = geoffcloud.config.services.imp;
  hostAtc = geoffcloud.config.services.atc-daemon;
  binds = hostTank.binds;
  # only the services this VM runs
  vmServices = [
    "k3s"
    "imp-host"
    "imp-host-dns-token"
    "atc-daemon"
  ];
  requiredBy = lib.filterAttrs (name: _: builtins.elem name vmServices) hostTank.requiredBy;
  dnsToken = "cf_fixture_TOKEN-0123456789abcdefghij";
  stubOp = import ./test-utils/build-stub-op-read.nix { inherit pkgs; } {
    "op://cloud/imp-dns-cloudflare/credential" = dnsToken;
    "op://cloud/imp-dns-cloudflare/acme-email" = "acme@example.net";
  };
  installDnsToken = ../../scripts/install-imp-dns-token.sh;
  writeGatewayToken = ../../scripts/host/write-atc-gateway-token.sh;
in
pkgs.testers.runNixOSTest {
  name = "tank-cloud-host-secrets";
  nodes.machine =
    { config, ... }:
    {
      imports = [
        imp.nixosModules.imp
        ../modules/tank-cloud.nix
        ../modules/atc-daemon.nix
      ];
      networking.hostId = "5ca71846";
      # the VM reaches nothing, and dhcpcd crashing at times would fail a unit at boot
      networking.useDHCP = false;
      # imp-host's podman run passes --device /dev/kvm
      boot.kernelModules = [
        "kvm-amd"
        "kvm-intel"
      ];
      boot.supportedFilesystems = [ "zfs" ];
      boot.zfs.forceImportRoot = false;
      virtualisation.emptyDiskImages = [ 4096 ];
      virtualisation.memorySize = 2048;
      # the subtests make a scenario database with sqlite3 and run copy-impd-db-host from PATH, as
      # geoffcloud does
      environment.systemPackages = [
        pkgs.sqlite
        impdDbTools
      ];

      services.imp = {
        enable = true;
        image = "ghcr.io/zgeoff/imp-host:2.1.0";
        imageArchive = image.archive;
        zfs.arcMaxMiB = 64;
        ramBudgetMiB = 512;
        # geoffcloud's own paths
        inherit (hostImp)
          tailscaleAuthKeyFile
          environmentFile
          backupPasswordFile
          dnsApiTokenFile
          ;
      };
      services.atc-daemon = {
        enable = true;
        package = atc;
        listen = "127.0.0.1:8415";
        inherit (hostAtc) tokenFile impTokenFile;
        targets.fixture = {
          provider = "imp";
          url = "http://127.0.0.1:7070";
          tokenFile = "/run/credentials/atc-daemon.service/imp-token";
          impPrefix = "harness-";
        };
        defaultTarget = "fixture";
        principals.fixture-client.targets = [ "fixture" ];
      };

      services.tank-cloud = {
        enable = true;
        inherit binds requiredBy;
      };
      # a stand-in for k3s, which geoffcloud's requiredBy ties to the rancher mount
      systemd.services.k3s = {
        description = "stand-in k3s";
        wantedBy = [ "multi-user.target" ];
        script = "exec sleep infinity";
      };
      # as geoffcloud: the path unit watches the bind, never the directory under it
      systemd.paths.imp-host-dns-token = {
        unitConfig = {
          inherit (geoffcloud.config.systemd.paths.imp-host-dns-token.unitConfig)
            DefaultDependencies
            RequiresMountsFor
            ;
        };
        inherit (geoffcloud.config.systemd.paths.imp-host-dns-token)
          requires
          after
          conflicts
          before
          ;
      };
      # the VM mounts virtualisation.fileSystems in place of fileSystems
      virtualisation.fileSystems = config.services.tank-cloud.fileSystems;

      # the pool, made once on the empty disk before its first import; zpool create leaves a
      # partition table, so a later boot finds one and only imports the pool
      systemd.services.check-pool = {
        requiredBy = [ "zfs-import-tank.service" ];
        before = [ "zfs-import-tank.service" ];
        requires = [ "dev-vdb.device" ];
        after = [ "dev-vdb.device" ];
        unitConfig.DefaultDependencies = false;
        path = [
          config.boot.zfs.package
          pkgs.util-linux
          pkgs.kmod
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # zpool create enables only the features that the module lists in sysfs, which it fills in
        # after /dev/zfs appears, so the module loads in full first
        script = ''
          modprobe zfs
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
    imp_secrets = "${binds.imp-host-secrets.path}"
    atc_secrets = "${binds.atc-daemon-secrets.path}"
    db_backups = "${binds.root-imp-db-backups.path}"
    tank = "/var/lib/tank-cloud"
    path_unit = "imp-host-dns-token.path"
    dns_token = "${dnsToken}"
    gateway_token = "gateway-fixture-bearer-0123456789abcdef-0123456789abcdef"
    staged_token = "/run/atc-daemon/gateway-token"


    def mount_unit(path):
        return machine.succeed(f"systemd-escape -p --suffix=mount {path}").strip()


    def mounts():
        """each bind path's source and file system type, as findmnt prints them"""
        return [machine.succeed(f"findmnt -rn -o SOURCE,FSTYPE --mountpoint {path}").strip() for path in [imp_secrets, atc_secrets, db_backups]]


    def assert_no_ordering_cycle():
        """systemd breaks an ordering cycle by deleting one of its jobs, and which one can differ
        from boot to boot, so a cycle fails a unit only at times: the journal names every one"""
        cycles = machine.succeed("journalctl -b -q --no-pager --grep 'ordering cycle' || true").strip()
        assert cycles == "", f"the boot has an ordering cycle: {cycles}"


    def assert_daemon_serving(token):
        """the atc daemon listens, which it does only after it loads its token file, on a copy of
        the token that its own user owns with mode 0600, as atc's --token-file needs"""
        machine.wait_for_open_port(8415, timeout=60)
        state = machine.succeed("systemctl show -P ActiveState atc-daemon.service").strip()
        assert state == "active", f"atc-daemon.service is {state}"
        owner = machine.succeed(f"stat -c '%U %a' {staged_token}").strip()
        assert owner == "atc 600", f"{staged_token} is {owner}"
        assert machine.succeed(f"cat {staged_token}") == token + "\n"


    machine.wait_for_unit("multi-user.target")


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"
        assert_no_ordering_cycle()


    # the rancher mount's wait for its device is still queued; cancel it, so the zvol that
    # zfs create makes does not start an fsck under mkfs
    machine.succeed("systemctl cancel")

    with subtest("it mounts the binds, and imp-host and the atc daemon read the files from tank/cloud"):
        machine.succeed("install -d -m 0700 /var/lib/zfs-keys")
        machine.succeed(f"printf '%s' {key} > /var/lib/zfs-keys/tank.key")
        machine.succeed("chmod 0400 /var/lib/zfs-keys/tank.key")
        machine.succeed(
            "zfs create -o encryption=aes-256-gcm -o keyformat=hex"
            " -o keylocation=file:///var/lib/zfs-keys/tank.key -o compression=lz4 -o mountpoint=legacy tank/cloud"
        )
        machine.succeed("zfs create -o mountpoint=legacy tank/cloud/host-secrets")
        machine.succeed("zfs create -o mountpoint=legacy tank/cloud/imp-db-backups")
        machine.succeed("zfs create -s -V 64G tank/cloud/rancher")
        machine.succeed("udevadm settle")
        machine.succeed("mkfs.ext4 -q -L rancher /dev/zvol/tank/cloud/rancher")
        machine.succeed("systemctl start tank-cloud-key.service")
        for path in [tank + "/host-secrets", tank + "/imp-db-backups"]:
            machine.succeed(f"systemctl start '{mount_unit(path)}'")
        # fake secrets in geoffcloud's shapes, in the directories the binds mount
        machine.succeed(f"install -d -m 0700 {tank}/host-secrets/imp-host {tank}/host-secrets/atc-daemon")
        machine.succeed(f"chmod 0700 {tank}/host-secrets {tank}/imp-db-backups")
        for name, content in [
            ("tailscale-authkey", "tskey-fixture"),
            ("backup-password", "backup-fixture"),
            ("imp-host.env", "IMP_FIXTURE=1"),
            ("dns-api-token", dns_token + "-old"),
        ]:
            path = f"{tank}/host-secrets/imp-host/{name}"
            machine.succeed(f"printf '%s\\n' {content} > {path} && chmod 0400 {path}")
        for name, content in [("gateway-token", gateway_token), ("imp-token", "imp-fixture-bearer")]:
            path = f"{tank}/host-secrets/atc-daemon/{name}"
            machine.succeed(f"printf '%s\\n' {content} > {path} && chmod 0400 {path}")
        machine.succeed("systemctl reset-failed")

        machine.succeed(f"systemctl start tank-cloud.target k3s.service imp-host.service atc-daemon.service {path_unit}")

        assert_no_ordering_cycle()
        found = mounts()
        assert found == [
            "tank/cloud/host-secrets[/imp-host] zfs",
            "tank/cloud/host-secrets[/atc-daemon] zfs",
            "tank/cloud/imp-db-backups zfs",
        ], f"the mounts are {found}"
        machine.wait_for_unit("k3s.service")
        machine.wait_for_unit("imp-host.service")
        machine.wait_for_unit("atc-daemon.service")
        machine.wait_for_unit(path_unit)
        machine.fail("journalctl -b -u imp-host.service --no-pager | grep 'is missing or empty'")
        # imp-host staged its copies from the files on tank/cloud, and the daemon loaded its credential from there
        machine.succeed(f"cmp /run/imp-host/backup-password {tank}/host-secrets/imp-host/backup-password")
        machine.succeed(f"cmp /run/imp-host/tailscale-authkey {tank}/host-secrets/imp-host/tailscale-authkey")
        machine.succeed(f"cmp /run/credentials/atc-daemon.service/gateway-token {tank}/host-secrets/atc-daemon/gateway-token")
        machine.succeed(f"cmp /run/credentials/atc-daemon.service/imp-token {tank}/host-secrets/atc-daemon/imp-token")
        assert_daemon_serving(gateway_token)


    with subtest("it takes an impd database copy onto tank/cloud"):
        machine.succeed("podman exec imp-host mkdir -p /var/lib/imp/db")
        machine.succeed(
            "sqlite3 /tmp/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);'"
            " \"INSERT INTO kysely_migration VALUES ('0001_init','t');\""
        )
        machine.succeed("podman cp /tmp/imp.sqlite imp-host:/var/lib/imp/db/imp.sqlite")
        copied = machine.succeed("copy-impd-db-host fixture")
        copy_dir = copied.splitlines()[-1].split("copy: ")[1].split(" ")[0]
        source = machine.succeed(f"findmnt -n -o SOURCE -T {copy_dir}/imp.sqlite").strip()

        assert source == "tank/cloud/imp-db-backups", f"the copy is on {source}"
        assert machine.succeed(f"ls -A {tank}/imp-db-backups/{copy_dir.split('/')[-1]}").split() == ["COPY-INFO", "imp.sqlite"]


    with subtest("it writes the install scripts' files onto tank/cloud and leaves the root disk empty"):
        assert machine.succeed("cat /run/imp-host/dns/token") == dns_token + "-old\n"
        installed = machine.succeed("IMP_HOST=local PATH=${stubOp}/bin:$PATH bash ${installDnsToken}")

        assert installed.startswith(f"installed: token file {imp_secrets}/dns-api-token ({len(dns_token)} bytes, mode 400); {imp_secrets}/imp-host.env has 1 email line, 0 token lines, mode 400"), installed
        machine.succeed(f"rm {atc_secrets}/gateway-token")
        machine.succeed(f"(cat ${writeGatewayToken}; printf '%s\\n' {gateway_token}-new) | bash -s -- {atc_secrets}")
        for path, expected in [
            (f"{imp_secrets}/dns-api-token", "tank/cloud/host-secrets[/imp-host]"),
            (f"{imp_secrets}/imp-host.env", "tank/cloud/host-secrets[/imp-host]"),
            (f"{atc_secrets}/gateway-token", "tank/cloud/host-secrets[/atc-daemon]"),
        ]:
            source = machine.succeed(f"findmnt -n -o SOURCE -T {path}").strip()
            assert source == expected, f"{path} is on {source}"
        assert machine.succeed(f"cat {atc_secrets}/gateway-token") == gateway_token + "-new\n"
        machine.succeed("systemctl restart atc-daemon.service")
        assert_daemon_serving(gateway_token + "-new")
        machine.succeed("mkdir -p /mnt/root-disk && mount --bind / /mnt/root-disk")
        for path in [imp_secrets, atc_secrets, db_backups]:
            left = machine.succeed(f"ls -A /mnt/root-disk{path}")
            assert left == "", f"{path} on the root disk holds {left!r}"
        machine.succeed("umount /mnt/root-disk")
        # the path unit watches the bind: it stages the new token without the five-minute timer
        machine.wait_until_succeeds(f"cmp /run/imp-host/dns/token {imp_secrets}/dns-api-token")
        assert machine.succeed("cat /run/imp-host/dns/token") == dns_token


    with subtest("it mounts the binds again after a reboot, and starts imp-host and the atc daemon on the files there"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        assert_no_ordering_cycle()
        machine.wait_for_unit("imp-host.service")
        machine.wait_for_unit("atc-daemon.service")

        assert mounts() == [
            "tank/cloud/host-secrets[/imp-host] zfs",
            "tank/cloud/host-secrets[/atc-daemon] zfs",
            "tank/cloud/imp-db-backups zfs",
        ]
        machine.fail("journalctl -b -u imp-host.service --no-pager | grep 'is missing or empty'")
        machine.succeed(f"cmp /run/credentials/atc-daemon.service/gateway-token {atc_secrets}/gateway-token")
        assert_daemon_serving(gateway_token + "-new")
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units failed after the reboot: {failed}"
  '';
}
