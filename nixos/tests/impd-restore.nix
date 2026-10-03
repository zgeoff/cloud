# A restore rehearsal for scripts/restore-impd-db.sh in a NixOS VM: a real ZFS pool with the
# legacy dataset tank/imp, real docker containers named imp-host and imp-docker-proxy, real
# generations in the system profile and a real switch-to-configuration. Stand-ins: busybox
# images that only sleep, tagged but without a digest, and generations that are this VM's own
# specialisations. It needs KVM, so CI does not run it; the run command is in
# docs/runbooks/restore-geoff-cloud.md, section 2.
let
  flake = builtins.getFlake "path:${toString ../.}";
  pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;

  mkImage =
    tag:
    pkgs.dockerTools.buildImage {
      name = "ghcr.io/zgeoff/imp-host";
      inherit tag;
      copyToRoot = pkgs.buildEnv {
        name = "imp-host-standin-root";
        paths = [ pkgs.busybox ];
        pathsToLink = [ "/bin" ];
      };
      config.Cmd = [
        "sleep"
        "infinity"
      ];
    };
  images = {
    "0.28.0" = mkImage "0.28.0";
    "0.29.0" = mkImage "0.29.0";
  };

  # the units as imp's module shapes them: Type=exec around a foreground docker run
  impUnits =
    { config, ... }:
    let
      image = "ghcr.io/zgeoff/imp-host:${config.rehearsal.impVersion}";
      docker = "${pkgs.docker}/bin/docker";
    in
    {
      options.rehearsal.impVersion = lib.mkOption { type = lib.types.str; };
      config = {
        systemd.services.imp-host-image = {
          requires = [ "docker.service" ];
          after = [ "docker.service" ];
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = true;
          script = ''
            ${docker} load -q -i ${images.${config.rehearsal.impVersion}}
          '';
        };
        systemd.services.imp-docker-proxy = {
          wantedBy = [ "multi-user.target" ];
          requires = [
            "docker.service"
            "imp-host-image.service"
          ];
          after = [
            "docker.service"
            "imp-host-image.service"
          ];
          serviceConfig = {
            Type = "exec";
            ExecStartPre = [ "-${docker} rm -f imp-docker-proxy" ];
            ExecStart = "${docker} run --init --rm --name imp-docker-proxy ${image} sleep infinity";
            ExecStop = "${docker} stop -t 10 imp-docker-proxy";
            Restart = "always";
            RestartSec = 2;
          };
        };
        systemd.services.imp-host = {
          wantedBy = [ "multi-user.target" ];
          requires = [
            "docker.service"
            "imp-host-image.service"
          ];
          wants = [ "imp-docker-proxy.service" ];
          after = [
            "docker.service"
            "imp-host-image.service"
            "imp-docker-proxy.service"
          ];
          serviceConfig = {
            Type = "exec";
            ExecStartPre = [ "-${docker} rm -f imp-host" ];
            ExecStart = "${docker} run --init --rm --name imp-host --hostname imp-host ${image}";
            ExecStop = "${docker} stop -t 120 imp-host";
            Restart = "on-failure";
            RestartSec = 5;
          };
        };
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "impd-restore-rehearsal";
  nodes.machine =
    { ... }:
    {
      imports = [ impUnits ];
      networking.hostId = "5ca71846";
      boot.supportedFilesystems = [ "zfs" ];
      boot.zfs.forceImportRoot = false;
      virtualisation.emptyDiskImages = [ 1024 ];
      virtualisation.memorySize = 2048;
      virtualisation.docker.enable = true;
      environment.systemPackages = [
        pkgs.sqlite
        pkgs.zfs
      ];
      rehearsal.impVersion = "0.29.0";
      specialisation.old.configuration.rehearsal.impVersion = lib.mkForce "0.28.0";
      # a switch that fails: a new unit fails to start during activation
      specialisation.broken.configuration = {
        rehearsal.impVersion = lib.mkForce "0.28.0";
        systemd.services.fail-on-switch = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          script = "exit 1";
        };
      };
    };

  testScript = ''
    import re
    restore = "bash ${../../scripts/restore-impd-db.sh}"
    env = "SQLITE3=sqlite3"
    profile = "/nix/var/nix/profiles/system"

    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("docker inspect imp-host --format '{{.Config.Image}}' | grep -x ghcr.io/zgeoff/imp-host:0.29.0")

    with subtest("pool, legacy dataset, a WAL database and secrets"):
        machine.succeed("zpool create -f tank /dev/vdb")
        machine.succeed("zfs create -o mountpoint=legacy tank/imp")
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite "
            "'PRAGMA journal_mode=WAL;' "
            "'.dbconfig no_ckpt_on_close on' "
            "'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' "
            "\"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" "
            "'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        print(machine.succeed("ls -la /mnt/imp/db"))
        machine.succeed("test -s /mnt/imp/db/imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")

    with subtest("a copy from the 0.28.0 generation, with the new COPY-INFO names"):
        c = "/root/imp-db-backups/pre-0.29-20261004T000000"
        machine.succeed(f"install -d -m 0700 {c}")
        machine.succeed(
            f"sqlite3 {c}/imp.sqlite "
            "'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' "
            "\"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" "
            "'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        size = machine.succeed(f"stat -c %s {c}/imp.sqlite").strip()
        machine.succeed(
            f"printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' 'sizeBytes {size}' 'lastMigration 0002_tokens' "
            "'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' "
            f"'image ghcr.io/zgeoff/imp-host:0.28.0' > {c}/COPY-INFO"
        )

    with subtest("generations: 0.28.0, broken, then the running 0.29.0"):
        machine.succeed(f"nix-env -p {profile} --set $(readlink -f /run/current-system/specialisation/old)")
        machine.succeed(f"nix-env -p {profile} --set $(readlink -f /run/current-system/specialisation/broken)")
        machine.succeed(f"nix-env -p {profile} --set $(readlink -f /run/current-system)")
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'")
        print(links)
        print(machine.succeed("grep -o 'ghcr.io/zgeoff/imp-host:[^ ;]*' /nix/var/nix/profiles/system-*-link/etc/systemd/system/imp-host.service"))
        gens = sorted(int(m) for m in re.findall(r"system-(\d+)-link", links))
        old_gen, broken_gen, new_gen = gens[-3:]
        old_path = machine.succeed(f"readlink -f {profile}-{old_gen}-link").strip()
        broken_path = machine.succeed(f"readlink -f {profile}-{broken_gen}-link").strip()

    with subtest("refuses while imp-host runs"):
        out = machine.fail(f"{env} {restore} {c} {old_gen} 2>&1")
        print(out)
        assert "not stopped" in out, out

    with subtest("restore the copy and roll back to the 0.28.0 generation"):
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        out = machine.succeed(f"{env} {restore} {c} {old_gen} 2>&1")
        print(out)
        machine.fail("findmnt -rn -S tank/imp")
        machine.fail("ls -d /run/impd-restore.*")
        assert machine.succeed("readlink -f /run/current-system").strip() == old_path
        machine.succeed("systemctl is-active imp-host")
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "ghcr.io/zgeoff/imp-host:0.28.0", image
        saved = machine.succeed("ls -d /root/imp-db-backups/pre-restore-* | head -1").strip()
        print(machine.succeed(f"find {saved} -printf '%M %u:%g %s %p\\n'"))
        machine.succeed(f"test -s {saved}/imp.sqlite && test -s {saved}/imp.sqlite-wal && test -s {saved}/secrets/glm")
        machine.succeed(f"test $(stat -c %a {saved}) = 700")
        machine.succeed(f"test -z \"$(find {saved} ! -user root)\"")
        machine.succeed(f"test -z \"$(find {saved} -perm /077 ! -type d)\"")
        machine.succeed(f"sqlite3 {saved}/imp.sqlite 'SELECT v FROM marker' | grep -x original")
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        machine.succeed(f"cmp {c}/imp.sqlite /mnt/imp/db/imp.sqlite")
        machine.succeed("test ! -e /mnt/imp/db/imp.sqlite-wal && test ! -e /mnt/imp/db/imp.sqlite.restore")
        machine.succeed("cmp /mnt/imp/secrets/glm " + saved + "/secrets/glm")
        machine.succeed("umount /mnt/imp")

    with subtest("a real switch failure stops both units again"):
        out = machine.fail(f"{env} {restore} {c} {broken_gen} 2>&1")
        print(out)
        assert "stopped again" in out, out
        machine.fail("systemctl is-active imp-host")
        machine.fail("systemctl is-active imp-docker-proxy")
        machine.fail("findmnt -rn -S tank/imp")
        # the activation ran; only a unit failed
        assert machine.succeed("readlink -f /run/current-system").strip() == broken_path
  '';
}
