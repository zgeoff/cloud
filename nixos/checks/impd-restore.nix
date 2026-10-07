# A restore rehearsal for scripts/restore-impd-db.sh in a NixOS VM: imp's own NixOS module (the
# flake's pinned imp input) runs imp-host and imp-docker-proxy, on a real ZFS pool with the
# module's legacy dataset tank/imp, real generations in the system profile and a real
# switch-to-configuration. The images are pinned by tag and digest, as geoffcloud pins them, and
# pulled from a registry inside the VM that answers for ghcr.io.
#
# Stand-ins: an imp-host image of busybox that only sleeps, with a proxy that only opens its
# socket; that local registry; generations that are this VM's own specialisations.
#
# One VM boots once. setup_case() returns it to the same boot state before each subtest: the
# 0.29.0 system running, its image pulled fresh, an empty tank/imp, generations 1 to 3. Each
# subtest writes its own database, secret, copy and COPY-INFO, so every subtest stands alone. It
# needs KVM, and it reads scripts/ beside nixos/, so it builds only from the repo root: run
# `bun run test:nixos impd-restore`.
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;

  # imp-docker-proxy's command in imp's image: here it only opens the socket the module waits for
  proxyStandin = pkgs.writeTextFile {
    name = "imp-docker-proxy-standin";
    destination = "/usr/local/bin/imp-docker-proxy";
    executable = true;
    text = ''
      #!/bin/sh
      exec ${pkgs.socat}/bin/socat UNIX-LISTEN:/run/imp-docker/docker.sock,fork EXEC:/bin/true
    '';
  };

  # each image as an OCI layout, whose manifest digest is the digest the registry serves it under
  # (skopeo copies it with --preserve-digests); reading it at evaluation is import from derivation
  mkLayout =
    tag:
    let
      image = pkgs.dockerTools.buildImage {
        name = "ghcr.io/zgeoff/imp-host";
        inherit tag;
        copyToRoot = pkgs.buildEnv {
          name = "imp-host-standin-root";
          paths = [
            pkgs.busybox
            proxyStandin
          ];
          pathsToLink = [
            "/bin"
            "/usr/local/bin"
          ];
        };
        config.Cmd = [
          "sleep"
          "infinity"
        ];
      };
    in
    pkgs.runCommand "imp-host-${tag}-oci" { nativeBuildInputs = [ pkgs.skopeo ]; } ''
      skopeo --insecure-policy copy docker-archive:${image} oci:$out:${tag}
    '';
  layout28 = mkLayout "0.28.0";
  layout29 = mkLayout "0.29.0";
  digestOf = layout: (builtins.head (lib.importJSON "${layout}/index.json").manifests).digest;
  ref28 = "ghcr.io/zgeoff/imp-host:0.28.0@${digestOf layout28}";
  ref29 = "ghcr.io/zgeoff/imp-host:0.29.0@${digestOf layout29}";
in
pkgs.testers.runNixOSTest {
  name = "impd-restore-rehearsal";
  nodes.machine =
    { config, ... }:
    {
      imports = [ imp.nixosModules.imp ];
      networking.hostId = "5ca71846";
      # imp-host's docker run passes --device /dev/kvm
      boot.kernelModules = [
        "kvm-amd"
        "kvm-intel"
      ];
      boot.zfs.forceImportRoot = false;
      virtualisation.emptyDiskImages = [ 1024 ];
      virtualisation.memorySize = 2048;
      environment.systemPackages = [ pkgs.sqlite ];

      # the registry that answers for ghcr.io: plain HTTP on port 80, which Docker falls back to
      # for a registry it lists as insecure
      networking.hosts."127.0.0.1" = [ "ghcr.io" ];
      virtualisation.docker.daemon.settings."insecure-registries" = [ "ghcr.io" ];
      services.dockerRegistry = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 80;
      };
      systemd.services.docker-registry.serviceConfig.AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      # both images in it before the module first pulls one
      systemd.services.rehearsal-registry-images = {
        requiredBy = [ "imp-host-image.service" ];
        before = [ "imp-host-image.service" ];
        requires = [ "docker-registry.service" ];
        after = [ "docker-registry.service" ];
        path = [
          pkgs.curl
          pkgs.skopeo
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # docker-registry is Type=simple, so "after" orders on its start, not on its port: wait
        # until it answers before the first copy
        script = ''
          deadline=$((SECONDS + 30))
          until curl -sf -o /dev/null http://ghcr.io/v2/; do
            if [ "$SECONDS" -ge "$deadline" ]; then
              echo "the registry did not answer within 30 s" >&2
              exit 1
            fi
            sleep 0.1
          done
          skopeo --insecure-policy copy --preserve-digests --dest-tls-verify=false \
            oci:${layout28}:0.28.0 docker://ghcr.io/zgeoff/imp-host:0.28.0
          skopeo --insecure-policy copy --preserve-digests --dest-tls-verify=false \
            oci:${layout29}:0.29.0 docker://ghcr.io/zgeoff/imp-host:0.29.0
        '';
      };

      # the operator's pool, which imp's module expects and never creates: made once on the
      # empty disk, before the module makes its dataset
      systemd.services.rehearsal-pool = {
        requiredBy = [ "imp-zfs-dataset.service" ];
        before = [ "imp-zfs-dataset.service" ];
        path = [ config.boot.zfs.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = "zpool list tank >/dev/null 2>&1 || zpool create -f tank /dev/vdb";
      };
      services.imp = {
        enable = true;
        image = ref29;
        # rehearsal-pool makes and imports the pool
        zfs.importPool = false;
        zfs.arcMaxMiB = 64;
        ramBudgetMiB = 512;
      };
      specialisation.old.configuration.services.imp.image = lib.mkForce ref28;
      # a switch that fails: a new unit fails to start during activation
      specialisation.broken.configuration = {
        services.imp.image = lib.mkForce ref28;
        systemd.services.fail-on-switch = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          script = "exit 1";
        };
      };
    };

  testScript = ''
    import re

    machine.wait_for_unit("multi-user.target")
    # setup_case resets failed units, so a unit that failed at boot shows only here
    failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
    assert failed == "", f"units failed at boot: {failed}"


    def setup_case():
        """Returns the VM to its boot state, with nothing of an earlier subtest left: the 0.29.0
        system running with imp-host up on its freshly pulled image, an empty tank/imp, and the
        generations 1 (0.28.0), 2 (0.28.0, a switch that fails) and 3 (0.29.0, running). Returns
        the three systems' store paths."""
        base_path = machine.succeed("readlink -f /run/booted-system").strip()
        machine.succeed("systemctl reset-failed")
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {base_path}")
        machine.succeed(f"{base_path}/bin/switch-to-configuration test")
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("systemctl reset-failed")
        machine.succeed("docker ps -aq | xargs -r docker rm -f")
        machine.succeed("docker images -q ghcr.io/zgeoff/imp-host | sort -u | xargs -r docker rmi -f")
        images = machine.succeed("docker images -q ghcr.io/zgeoff/imp-host")
        assert images == "", f"images are left: {images}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"a restore left {leftovers}"
        machine.succeed("rm -rf /root/imp-db-backups /tmp/restore.err")

        machine.succeed("zfs destroy -r tank/imp")
        # imp's module makes the dataset again
        machine.succeed("systemctl restart imp-zfs-dataset")
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"

        machine.succeed("rm -f /nix/var/nix/profiles/system /nix/var/nix/profiles/system-*-link")
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set $(readlink -f {base_path}/specialisation/old)")
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set $(readlink -f {base_path}/specialisation/broken)")
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {base_path}")
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"

        machine.succeed("systemctl start imp-host")
        machine.wait_until_succeeds(
            "test \"$(docker inspect imp-host --format '{{.Config.Image}}')\" = ${ref29}"
        )
        machine.wait_for_unit("imp-docker-proxy.service")
        return {
            "base_path": base_path,
            "old_path": machine.succeed("readlink -f /nix/var/nix/profiles/system-1-link").strip(),
            "broken_path": machine.succeed("readlink -f /nix/var/nix/profiles/system-2-link").strip(),
        }


    with subtest("it refuses to restore while imp-host runs, and changes nothing"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy', '== check the host'], out
        assert err.splitlines() == ['restore-impd-db: imp-host is active, not stopped; run: systemctl stop imp-host imp-docker-proxy', 'restore-impd-db: nothing was changed'], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"


    with subtest("it refuses to restore while imp-docker-proxy runs, and changes nothing"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy', '== check the host'], out
        assert err.splitlines() == ['restore-impd-db: imp-docker-proxy is active, not stopped; run: systemctl stop imp-host imp-docker-proxy', 'restore-impd-db: nothing was changed'], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"


    with subtest("it refuses to restore while an imp-host container runs without its unit, and changes nothing"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("docker run -d --rm --name imp-host ${ref29} sleep infinity")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy', '== check the host'], out
        assert err.splitlines() == ['restore-impd-db: the imp-host container still runs; stop it before a restore', 'restore-impd-db: nothing was changed'], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"
        machine.succeed("docker rm -f imp-host")


    with subtest("it restores the copy, saves the stopped database and switches to the copy's generation"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")

        before = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        after = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 0, f"exit {status}: {out}{err}"
        saved_dirs = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").split()
        assert len(saved_dirs) == 1, f"the saved directories are {saved_dirs}"
        saved = saved_dirs[0]
        stamp = saved.removeprefix("/root/imp-db-backups/pre-restore-")
        assert before <= stamp <= after, f"{stamp} is outside {before}..{after}"
        assert out.splitlines() == [
            "== check the copy",
            "== check the host",
            "== mount tank/imp",
            "== preserve the stopped database",
            f"saved: {saved}",
            "== stage and check the copy",
            "== publish",
            "== unmount",
            "== activate generation 1",
            # the activation script's own line, from switch-to-configuration
            "setting up /etc...",
            "== start",
            f"restored /root/imp-db-backups/pre-0.29-20261004T000000 (migration 0002_tokens) on generation 1; the replaced database is in {saved}",
        ], out
        # switch-to-configuration writes its progress to stderr: the units it stops, starts and
        # restarts, which vary with the generations; the script's own lines start with its name
        assert [line for line in err.splitlines() if line.startswith("restore-impd-db:")] == [], err
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["old_path"], f"the system is {current}"
        # the switch sets the profile to the copy's system as a new generation
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-4-link", f"the system profile is {profile}"
        profile_path = machine.succeed("readlink -f /nix/var/nix/profiles/system-4-link").strip()
        assert profile_path == ctx["old_path"], f"generation 4 is {profile_path}"
        machine.succeed("systemctl is-active imp-host")
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${ref28}", image
        listing = machine.succeed(f"cd {saved} && find . -printf '%M %u:%g %p\\n' | sort -k3").splitlines()
        assert listing == [
            "drwx------ root:root .",
            "-rw------- root:root ./imp.sqlite",
            "-rw------- root:root ./imp.sqlite-shm",
            "-rw------- root:root ./imp.sqlite-wal",
            "drwx------ root:root ./secrets",
            "-rw------- root:root ./secrets/glm",
        ], listing
        saved_sums = machine.succeed(f"cd {saved} && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        assert saved_sums == db_sums, f"the saved database differs: {saved_sums}"
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        db_files = machine.succeed("ls -A /mnt/imp/db").split()
        published = machine.execute("cmp /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite /mnt/imp/db/imp.sqlite")[0]
        secret = machine.succeed("cat /mnt/imp/secrets/glm")
        secret_saved = machine.execute(f"cmp /mnt/imp/secrets/glm {saved}/secrets/glm")[0]
        machine.succeed("umount /mnt/imp")
        assert db_files == ["imp.sqlite"], f"the database files are {db_files}"
        assert published == 0, "the published database differs from the copy"
        assert secret == "dummy-secret-value\n", f"the secret reads {secret!r}"
        assert secret_saved == 0, "the saved secret differs from the one in place"


    with subtest("it reads the migration from a COPY-INFO that names it migration"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'migration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")

        before = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        after = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 0, f"exit {status}: {out}{err}"
        saved_dirs = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").split()
        assert len(saved_dirs) == 1, f"the saved directories are {saved_dirs}"
        saved = saved_dirs[0]
        stamp = saved.removeprefix("/root/imp-db-backups/pre-restore-")
        assert before <= stamp <= after, f"{stamp} is outside {before}..{after}"
        assert out.splitlines() == [
            "== check the copy",
            "== check the host",
            "== mount tank/imp",
            "== preserve the stopped database",
            f"saved: {saved}",
            "== stage and check the copy",
            "== publish",
            "== unmount",
            "== activate generation 1",
            # the activation script's own line, from switch-to-configuration
            "setting up /etc...",
            "== start",
            f"restored /root/imp-db-backups/pre-0.29-20261004T000000 (migration 0002_tokens) on generation 1; the replaced database is in {saved}",
        ], out
        # switch-to-configuration writes its progress to stderr: the units it stops, starts and
        # restarts, which vary with the generations; the script's own lines start with its name
        assert [line for line in err.splitlines() if line.startswith("restore-impd-db:")] == [], err
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["old_path"], f"the system is {current}"
        # the switch sets the profile to the copy's system as a new generation
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-4-link", f"the system profile is {profile}"
        profile_path = machine.succeed("readlink -f /nix/var/nix/profiles/system-4-link").strip()
        assert profile_path == ctx["old_path"], f"generation 4 is {profile_path}"
        machine.succeed("systemctl is-active imp-host")
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${ref28}", image
        listing = machine.succeed(f"cd {saved} && find . -printf '%M %u:%g %p\\n' | sort -k3").splitlines()
        assert listing == [
            "drwx------ root:root .",
            "-rw------- root:root ./imp.sqlite",
            "-rw------- root:root ./imp.sqlite-shm",
            "-rw------- root:root ./imp.sqlite-wal",
            "drwx------ root:root ./secrets",
            "-rw------- root:root ./secrets/glm",
        ], listing
        saved_sums = machine.succeed(f"cd {saved} && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        assert saved_sums == db_sums, f"the saved database differs: {saved_sums}"
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        db_files = machine.succeed("ls -A /mnt/imp/db").split()
        published = machine.execute("cmp /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite /mnt/imp/db/imp.sqlite")[0]
        secret = machine.succeed("cat /mnt/imp/secrets/glm")
        secret_saved = machine.execute(f"cmp /mnt/imp/secrets/glm {saved}/secrets/glm")[0]
        machine.succeed("umount /mnt/imp")
        assert db_files == ["imp.sqlite"], f"the database files are {db_files}"
        assert published == 0, "the published database differs from the copy"
        assert secret == "dummy-secret-value\n", f"the secret reads {secret!r}"
        assert secret_saved == 0, "the saved secret differs from the one in place"


    with subtest("it stops imp-host and imp-docker-proxy again when the switch fails"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 2 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        saved_dirs = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").split()
        assert len(saved_dirs) == 1, f"the saved directories are {saved_dirs}"
        saved = saved_dirs[0]
        # after these, switch-to-configuration prints the failed unit's status, with times and PIDs
        assert out.splitlines()[:10] == [
            "== check the copy",
            "== check the host",
            "== mount tank/imp",
            "== preserve the stopped database",
            f"saved: {saved}",
            "== stage and check the copy",
            "== publish",
            "== unmount",
            "== activate generation 2",
            "setting up /etc...",
        ], out
        later = [line for line in out.splitlines()[10:] if line.startswith(("== ", "saved: ", "restored "))]
        assert later == [], f"the script went on past the switch: {later}"
        # switch-to-configuration writes its progress to stderr; the script's own lines start with its name
        messages = [line for line in err.splitlines() if line.startswith("restore-impd-db:")]
        assert len(messages) == 2, err
        # the ERR trap names the script line, which moves with any edit to the script
        assert re.fullmatch(r"restore-impd-db: failed at line \d+", messages[0]), err
        assert messages[1] == (
            f"restore-impd-db: the copy is in place (the original is in {saved}); "
            "the switch or start did not finish; imp-host and imp-docker-proxy are stopped again"
        ), err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units[0] != "active" and units[1] != "active", f"the units are {units}"
        machine.fail("findmnt -rn -S tank/imp")
        # the activation ran; only a unit failed
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["broken_path"], f"the system is {current}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        published = machine.execute("cmp /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite /mnt/imp/db/imp.sqlite")[0]
        machine.succeed("umount /mnt/imp")
        assert published == 0, "the published database differs from the copy"


    with subtest("it restores without a switch when the copy's generation is the running one"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref29}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")

        before = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
        after = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 0, f"exit {status}: {out}{err}"
        saved_dirs = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").split()
        assert len(saved_dirs) == 1, f"the saved directories are {saved_dirs}"
        saved = saved_dirs[0]
        stamp = saved.removeprefix("/root/imp-db-backups/pre-restore-")
        assert before <= stamp <= after, f"{stamp} is outside {before}..{after}"
        assert out.splitlines() == [
            "== check the copy",
            "== check the host",
            "== mount tank/imp",
            "== preserve the stopped database",
            f"saved: {saved}",
            "== stage and check the copy",
            "== publish",
            "== unmount",
            "== activate generation 3",
            "== start",
            f"restored /root/imp-db-backups/pre-0.29-20261004T000000 (migration 0002_tokens) on generation 3; the replaced database is in {saved}",
        ], out
        assert err == "", err
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        # generation 3 is the running system, so nothing switches and no generation is added
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("systemctl is-active imp-host")
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${ref29}", image
        listing = machine.succeed(f"cd {saved} && find . -printf '%M %u:%g %p\\n' | sort -k3").splitlines()
        assert listing == [
            "drwx------ root:root .",
            "-rw------- root:root ./imp.sqlite",
            "-rw------- root:root ./imp.sqlite-shm",
            "-rw------- root:root ./imp.sqlite-wal",
            "drwx------ root:root ./secrets",
            "-rw------- root:root ./secrets/glm",
        ], listing
        saved_sums = machine.succeed(f"cd {saved} && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        assert saved_sums == db_sums, f"the saved database differs: {saved_sums}"
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        db_files = machine.succeed("ls -A /mnt/imp/db").split()
        published = machine.execute("cmp /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite /mnt/imp/db/imp.sqlite")[0]
        machine.succeed("umount /mnt/imp")
        assert db_files == ["imp.sqlite"], f"the database files are {db_files}"
        assert published == 0, "the published database differs from the copy"


    with subtest("it restores a database that has no -wal or -shm file, saving only the database and secrets"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref29}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")

        before = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
        after = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 0, f"exit {status}: {out}{err}"
        saved_dirs = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").split()
        assert len(saved_dirs) == 1, f"the saved directories are {saved_dirs}"
        saved = saved_dirs[0]
        stamp = saved.removeprefix("/root/imp-db-backups/pre-restore-")
        assert before <= stamp <= after, f"{stamp} is outside {before}..{after}"
        assert out.splitlines() == [
            "== check the copy",
            "== check the host",
            "== mount tank/imp",
            "== preserve the stopped database",
            f"saved: {saved}",
            "== stage and check the copy",
            "== publish",
            "== unmount",
            "== activate generation 3",
            "== start",
            f"restored /root/imp-db-backups/pre-0.29-20261004T000000 (migration 0002_tokens) on generation 3; the replaced database is in {saved}",
        ], out
        assert err == "", err
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        # generation 3 is the running system, so nothing switches and no generation is added
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("systemctl is-active imp-host")
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${ref29}", image
        listing = machine.succeed(f"cd {saved} && find . -printf '%M %u:%g %p\\n' | sort -k3").splitlines()
        assert listing == [
            "drwx------ root:root .",
            "-rw------- root:root ./imp.sqlite",
            "drwx------ root:root ./secrets",
            "-rw------- root:root ./secrets/glm",
        ], listing
        saved_sums = machine.succeed(f"cd {saved} && sha256sum imp.sqlite")
        assert saved_sums == db_sums, f"the saved database differs: {saved_sums}"
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        db_files = machine.succeed("ls -A /mnt/imp/db").split()
        published = machine.execute("cmp /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite /mnt/imp/db/imp.sqlite")[0]
        machine.succeed("umount /mnt/imp")
        assert db_files == ["imp.sqlite"], f"the database files are {db_files}"
        assert published == 0, "the published database differs from the copy"


    with subtest("it restores a dataset that has no secrets directory, saving only the database"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref29}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")

        before = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
        after = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 0, f"exit {status}: {out}{err}"
        saved_dirs = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").split()
        assert len(saved_dirs) == 1, f"the saved directories are {saved_dirs}"
        saved = saved_dirs[0]
        stamp = saved.removeprefix("/root/imp-db-backups/pre-restore-")
        assert before <= stamp <= after, f"{stamp} is outside {before}..{after}"
        assert out.splitlines() == [
            "== check the copy",
            "== check the host",
            "== mount tank/imp",
            "== preserve the stopped database",
            f"saved: {saved}",
            "== stage and check the copy",
            "== publish",
            "== unmount",
            "== activate generation 3",
            "== start",
            f"restored /root/imp-db-backups/pre-0.29-20261004T000000 (migration 0002_tokens) on generation 3; the replaced database is in {saved}",
        ], out
        assert err == "", err
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        # generation 3 is the running system, so nothing switches and no generation is added
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("systemctl is-active imp-host")
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${ref29}", image
        listing = machine.succeed(f"cd {saved} && find . -printf '%M %u:%g %p\\n' | sort -k3").splitlines()
        assert listing == [
            "drwx------ root:root .",
            "-rw------- root:root ./imp.sqlite",
            "-rw------- root:root ./imp.sqlite-shm",
            "-rw------- root:root ./imp.sqlite-wal",
        ], listing
        saved_sums = machine.succeed(f"cd {saved} && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        assert saved_sums == db_sums, f"the saved database differs: {saved_sums}"
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        db_files = machine.succeed("ls -A /mnt/imp/db").split()
        published = machine.execute("cmp /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite /mnt/imp/db/imp.sqlite")[0]
        machine.succeed("umount /mnt/imp")
        assert db_files == ["imp.sqlite"], f"the database files are {db_files}"
        assert published == 0, "the published database differs from the copy"


    with subtest("it stops both units again when no imp-host container appears within the wait"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref29}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        # docker run reads its seccomp profile before it creates the container: an invalid profile
        # makes every start fail with no container at all
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.succeed("printf '{' > /tmp/broken-seccomp.json")
        machine.succeed(f"mount --bind /tmp/broken-seccomp.json {seccomp[0]}")

        status, out = machine.execute("IMPD_START_WAIT_SECONDS=1 SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        machine.succeed(f"umount {seccomp[0]}")
        assert status == 1, f"exit {status}: {out}{err}"
        saved_dirs = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").split()
        assert len(saved_dirs) == 1, f"the saved directories are {saved_dirs}"
        saved = saved_dirs[0]
        assert out.splitlines() == [
            "== check the copy",
            "== check the host",
            "== mount tank/imp",
            "== preserve the stopped database",
            f"saved: {saved}",
            "== stage and check the copy",
            "== publish",
            "== unmount",
            "== activate generation 3",
            "== start",
        ], out
        assert err.splitlines() == [
            "restore-impd-db: no imp-host container appeared within 1 s of the start",
            f"restore-impd-db: the copy is in place (the original is in {saved}); "
            "the switch or start did not finish; imp-host and imp-docker-proxy are stopped again",
        ], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units[0] != "active" and units[1] != "active", f"the units are {units}"
        containers = machine.succeed("docker ps -a --format '{{.Names}}'").split()
        assert containers == [], f"the containers are {containers}"
        machine.fail("findmnt -rn -S tank/imp")
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"


    with subtest("it prints its usage, and changes nothing, without arguments"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh}  2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out == "", out
        # bash names the script and the line of the failed expansion; the line moves with any edit
        normalized = re.sub(r": line [0-9]+: ", ": line N: ", err)
        assert normalized == "${../../scripts/restore-impd-db.sh}: line N: 1: usage: restore-impd-db.sh /root/imp-db-backups/<copy> <generation>\n", err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"


    with subtest("it refuses a copy without imp.sqlite, and changes nothing"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' 'sizeBytes 0' 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy'], out
        assert err.splitlines() == ['restore-impd-db: /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite is missing', 'restore-impd-db: nothing was changed'], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"


    with subtest("it refuses a copy that fails integrity_check, and changes nothing"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed("printf 'not a database\\n' > /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite")
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy'], out
        assert err.splitlines() == ['Error: in prepare, file is not a database (26)', 'restore-impd-db: the copy fails integrity_check', 'restore-impd-db: nothing was changed'], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"


    with subtest("it refuses a copy without COPY-INFO, and changes nothing"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy'], out
        assert err.splitlines() == ['restore-impd-db: /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO is missing; only a copy-impd-db.sh copy is restorable', 'restore-impd-db: nothing was changed'], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"


    with subtest("it refuses a COPY-INFO without an image, and changes nothing"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy'], out
        assert err.splitlines() == ['restore-impd-db: COPY-INFO lacks the image or the migration', 'restore-impd-db: nothing was changed'], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"


    with subtest("it refuses a COPY-INFO without a migration, and changes nothing"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy'], out
        assert err.splitlines() == ['restore-impd-db: COPY-INFO lacks the image or the migration', 'restore-impd-db: nothing was changed'], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"


    with subtest("it refuses a copy whose newest migration differs from COPY-INFO, and changes nothing"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0003_leases' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy'], out
        assert err.splitlines() == ["restore-impd-db: the copy's newest migration differs from COPY-INFO", 'restore-impd-db: nothing was changed'], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"


    with subtest("it refuses a generation that is not a number, and changes nothing"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 old 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy', '== check the host'], out
        assert err.splitlines() == ['restore-impd-db: the generation must be a number, such as 14', 'restore-impd-db: nothing was changed'], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"


    with subtest("it refuses a generation that does not exist, and changes nothing"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 99 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy', '== check the host'], out
        assert err.splitlines() == ['restore-impd-db: generation 99 does not exist', 'restore-impd-db: nothing was changed'], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"


    with subtest("it refuses a generation that runs another image than the copy's, and changes nothing"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy', '== check the host'], out
        assert err.splitlines() == ['restore-impd-db: generation 3 runs ${ref29}, but the copy is from ${ref28}', 'restore-impd-db: nothing was changed'], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"


    with subtest("it refuses while tank/imp is mounted, and changes nothing"):
        ctx = setup_case()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy', '== check the host'], out
        assert err.splitlines() == ['restore-impd-db: tank/imp is already mounted', 'restore-impd-db: nothing was changed'], err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        mounts = machine.succeed("findmnt -rn -S tank/imp -o TARGET").split()
        assert mounts == ["/mnt/imp"], f"tank/imp is mounted at {mounts}"
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"


    with subtest("it refuses a dataset without imp.sqlite, and changes nothing"):
        ctx = setup_case()
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${ref28}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        dataset_before = machine.succeed("cd /mnt/imp && find . | sort")
        machine.succeed("umount /mnt/imp")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ["== check the copy", "== check the host", "== mount tank/imp"], out
        err_lines = err.splitlines()
        assert len(err_lines) == 2, err
        # the mountpoint is a fresh mktemp directory
        assert re.fullmatch(r"restore-impd-db: /run/impd-restore\.\w{6}/db/imp\.sqlite is missing; is tank/imp impd's dataset\?", err_lines[0]), err
        assert err_lines[1] == "restore-impd-db: nothing was changed", err
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        dataset_after = machine.succeed("cd /mnt/imp && find . | sort")
        machine.succeed("umount /mnt/imp")
        assert dataset_after == dataset_before, f"the dataset changed: {dataset_after}"

  '';
}
