# A restore rehearsal for scripts/restore-impd-db.sh in a NixOS VM: imp's own NixOS module (the
# flake's pinned imp input) runs imp-host and imp-docker-proxy, on a real ZFS pool with the
# module's legacy dataset tank/imp, real generations in the system profile and a real
# switch-to-configuration. Stand-ins: an imp-host image of busybox that only sleeps, with a proxy
# that only opens its socket, tagged but without a digest; generations that are this VM's own
# specialisations. One VM boots once; setup_case() rebuilds tank/imp, the database, the copy and
# the generations before each subtest, so every subtest stands alone. It needs KVM; the run
# command is in docs/runbooks/restore-geoff-cloud.md, section 2.
let
  flake = builtins.getFlake "path:${toString ../.}";
  pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;
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

  mkImage =
    tag:
    pkgs.dockerTools.buildImage {
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
  images = {
    "0.28.0" = mkImage "0.28.0";
    "0.29.0" = mkImage "0.29.0";
  };
in
pkgs.testers.runNixOSTest {
  name = "impd-restore-rehearsal";
  nodes.machine =
    { config, ... }:
    {
      imports = [ flake.inputs.imp.nixosModules.imp ];
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
        image = "ghcr.io/zgeoff/imp-host:0.29.0";
        imageArchive = images."0.29.0";
        # rehearsal-pool makes and imports the pool
        zfs.importPool = false;
        zfs.arcMaxMiB = 64;
        ramBudgetMiB = 512;
      };
      specialisation.old.configuration.services.imp = {
        image = lib.mkForce "ghcr.io/zgeoff/imp-host:0.28.0";
        imageArchive = lib.mkForce images."0.28.0";
      };
      # a switch that fails: a new unit fails to start during activation
      specialisation.broken.configuration = {
        services.imp = {
          image = lib.mkForce "ghcr.io/zgeoff/imp-host:0.28.0";
          imageArchive = lib.mkForce images."0.28.0";
        };
        systemd.services.fail-on-switch = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          script = "exit 1";
        };
      };
    };

  testScript = ''
    import re

    restore = "SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh}"
    profile = "/nix/var/nix/profiles/system"
    copy = "/root/imp-db-backups/pre-0.29-20261004T000000"
    image_format = "'{{.Config.Image}}'"

    machine.wait_for_unit("multi-user.target")
    base_path = machine.succeed("readlink -f /run/booted-system").strip()


    def setup_case():
        """Returns the VM to one known state: the 0.29.0 system running with imp-host up on it, a
        fresh tank/imp that holds a WAL database (with its -wal and -shm files) and a secret, a 0.28.0 copy with COPY-INFO,
        and the generations 1 (0.28.0), 2 (0.28.0, a switch that fails) and 3 (0.29.0)."""
        machine.succeed("systemctl reset-failed")
        machine.succeed(f"nix-env -p {profile} --set {base_path}")
        machine.succeed(f"{base_path}/bin/switch-to-configuration test")
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("systemctl reset-failed")
        machine.succeed("{ findmnt -rn -S tank/imp -o TARGET || true; } | xargs -r umount")
        machine.succeed("zfs destroy -r tank/imp")
        machine.succeed("rm -rf /root/imp-db-backups /mnt/imp /run/impd-restore.* /tmp/restore.err")

        # imp's module makes the dataset again
        machine.succeed("systemctl restart imp-zfs-dataset")
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
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
        db_files = machine.succeed("ls -A /mnt/imp/db").split()
        assert db_files == ["imp.sqlite", "imp.sqlite-shm", "imp.sqlite-wal"], f"the database files are {db_files}"
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")

        machine.succeed(f"install -d -m 0700 {copy}")
        machine.succeed(
            f"sqlite3 {copy}/imp.sqlite "
            "'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' "
            "\"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" "
            "'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        size = machine.succeed(f"stat -c %s {copy}/imp.sqlite").strip()
        machine.succeed(
            f"printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' 'sizeBytes {size}' 'lastMigration 0002_tokens' "
            "'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' "
            f"'image ghcr.io/zgeoff/imp-host:0.28.0' > {copy}/COPY-INFO"
        )

        machine.succeed(f"rm -f {profile} {profile}-*-link")
        machine.succeed(f"nix-env -p {profile} --set $(readlink -f {base_path}/specialisation/old)")
        machine.succeed(f"nix-env -p {profile} --set $(readlink -f {base_path}/specialisation/broken)")
        machine.succeed(f"nix-env -p {profile} --set {base_path}")
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"

        machine.succeed("systemctl start imp-host")
        machine.wait_until_succeeds(
            f"test \"$(docker inspect imp-host --format {image_format})\" = ghcr.io/zgeoff/imp-host:0.29.0"
        )
        machine.wait_for_unit("imp-docker-proxy.service")
        return {
            "db_sums": db_sums,
            "old_path": machine.succeed(f"readlink -f {profile}-1-link").strip(),
            "broken_path": machine.succeed(f"readlink -f {profile}-2-link").strip(),
        }


    with subtest("it refuses to restore while imp-host runs, and changes nothing"):
        ctx = setup_case()

        status, out = machine.execute(f"{restore} {copy} 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ["== check the copy", "== check the host"], out
        assert err.splitlines() == [
            "restore-impd-db: imp-host is active, not stopped; run: systemctl stop imp-host imp-docker-proxy",
            "restore-impd-db: nothing was changed",
        ], err
        machine.succeed("systemctl is-active imp-host")
        backups = machine.succeed("ls -A /root/imp-db-backups").split()
        assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
        machine.fail("findmnt -rn -S tank/imp")
        machine.succeed("test -z \"$(ls -d /run/impd-restore.* 2>/dev/null)\"")
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == base_path, f"the system is {current}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        db_files = machine.succeed("ls -A /mnt/imp/db").split()
        machine.succeed("umount /mnt/imp")
        assert db_sums == ctx["db_sums"], f"the database changed: {db_sums}"
        assert db_files == ["imp.sqlite", "imp.sqlite-shm", "imp.sqlite-wal"], f"the database files are {db_files}"

    with subtest("it restores the copy, saves the stopped database and switches to the copy's generation"):
        ctx = setup_case()
        machine.succeed("systemctl stop imp-host imp-docker-proxy")

        status, out = machine.execute(f"{restore} {copy} 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 0, f"exit {status}: {out}{err}"
        saved_dirs = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").split()
        assert len(saved_dirs) == 1, f"the saved directories are {saved_dirs}"
        saved = saved_dirs[0]
        assert re.fullmatch(r"/root/imp-db-backups/pre-restore-\d{8}T\d{6}", saved), saved
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
            f"restored {copy} (migration 0002_tokens) on generation 1; the replaced database is in {saved}",
        ], out
        assert [line for line in err.splitlines() if line.startswith("restore-impd-db:")] == [], err
        machine.fail("findmnt -rn -S tank/imp")
        machine.succeed("test -z \"$(ls -d /run/impd-restore.* 2>/dev/null)\"")
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["old_path"], f"the system is {current}"
        # the switch sets the profile as a new generation of the copy's system
        profile_path = machine.succeed(f"readlink -f {profile}").strip()
        assert profile_path == ctx["old_path"], f"the system profile is {profile_path}"
        machine.succeed("systemctl is-active imp-host")
        image = machine.succeed(f"docker inspect imp-host --format {image_format}").strip()
        assert image == "ghcr.io/zgeoff/imp-host:0.28.0", image
        listing = machine.succeed(f"cd {saved} && find . -printf '%M %u:%g %p\\n' | sort -k3").splitlines()
        assert listing == [
            "drwx------ root:root .",
            "-rw------- root:root ./imp.sqlite",
            "-rw------- root:root ./imp.sqlite-shm",
            "-rw------- root:root ./imp.sqlite-wal",
            "drwx------ root:root ./secrets",
            "-rw------- root:root ./secrets/glm",
        ], listing
        marker = machine.succeed(f"sqlite3 {saved}/imp.sqlite 'SELECT v FROM marker'").strip()
        assert marker == "original", f"the saved database holds {marker!r}"
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        db_files = machine.succeed("ls -A /mnt/imp/db").split()
        machine.succeed(f"cmp {copy}/imp.sqlite /mnt/imp/db/imp.sqlite")
        secret = machine.succeed("cat /mnt/imp/secrets/glm")
        machine.succeed(f"cmp /mnt/imp/secrets/glm {saved}/secrets/glm")
        machine.succeed("umount /mnt/imp")
        assert db_files == ["imp.sqlite"], f"the database files are {db_files}"
        assert secret == "dummy-secret-value\n", f"the secret reads {secret!r}"

    with subtest("it reads the migration from a COPY-INFO that names it migration"):
        ctx = setup_case()
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed(f"sed -i 's/^lastMigration /migration /' {copy}/COPY-INFO")

        status, out = machine.execute(f"{restore} {copy} 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 0, f"exit {status}: {out}{err}"
        last = out.splitlines()[-1]
        assert re.fullmatch(
            rf"restored {re.escape(copy)} \(migration 0002_tokens\) on generation 1; "
            r"the replaced database is in /root/imp-db-backups/pre-restore-\d{8}T\d{6}",
            last,
        ), last
        image = machine.succeed(f"docker inspect imp-host --format {image_format}").strip()
        assert image == "ghcr.io/zgeoff/imp-host:0.28.0", image

    with subtest("it stops imp-host and imp-docker-proxy again when the switch fails"):
        ctx = setup_case()
        machine.succeed("systemctl stop imp-host imp-docker-proxy")

        status, out = machine.execute(f"{restore} {copy} 2 2>/tmp/restore.err")
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
        messages = [line for line in err.splitlines() if line.startswith("restore-impd-db:")]
        assert len(messages) == 2, err
        # the ERR trap names the script line, which moves with any edit to the script
        assert re.fullmatch(r"restore-impd-db: failed at line \d+", messages[0]), err
        assert messages[1] == (
            f"restore-impd-db: the copy is in place (the original is in {saved}); "
            "the switch or start did not finish; imp-host and imp-docker-proxy are stopped again"
        ), err
        machine.fail("systemctl is-active imp-host")
        machine.fail("systemctl is-active imp-docker-proxy")
        machine.fail("findmnt -rn -S tank/imp")
        # the activation ran; only a unit failed
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["broken_path"], f"the system is {current}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed(f"cmp {copy}/imp.sqlite /mnt/imp/db/imp.sqlite")
        machine.succeed("umount /mnt/imp")

    with subtest("it refuses a copy without COPY-INFO, and changes nothing"):
        ctx = setup_case()
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed(f"rm {copy}/COPY-INFO")

        status, out = machine.execute(f"{restore} {copy} 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ["== check the copy"], out
        assert err.splitlines() == [
            f"restore-impd-db: {copy}/COPY-INFO is missing; only a copy-impd-db.sh copy is restorable",
            "restore-impd-db: nothing was changed",
        ], err
        machine.fail("ls -d /root/imp-db-backups/pre-restore-*")
        machine.fail("findmnt -rn -S tank/imp")
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == base_path, f"the system is {current}"

    with subtest("it refuses a copy whose newest migration differs from COPY-INFO, and changes nothing"):
        ctx = setup_case()
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed(f"sed -i 's/^lastMigration 0002_tokens$/lastMigration 0003_leases/' {copy}/COPY-INFO")

        status, out = machine.execute(f"{restore} {copy} 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ["== check the copy"], out
        assert err.splitlines() == [
            "restore-impd-db: the copy's newest migration differs from COPY-INFO",
            "restore-impd-db: nothing was changed",
        ], err
        machine.fail("ls -d /root/imp-db-backups/pre-restore-*")
        machine.fail("findmnt -rn -S tank/imp")

    with subtest("it refuses a generation that is not a number, and changes nothing"):
        ctx = setup_case()
        machine.succeed("systemctl stop imp-host imp-docker-proxy")

        status, out = machine.execute(f"{restore} {copy} old 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ["== check the copy", "== check the host"], out
        assert err.splitlines() == [
            "restore-impd-db: the generation must be a number, such as 14",
            "restore-impd-db: nothing was changed",
        ], err
        machine.fail("ls -d /root/imp-db-backups/pre-restore-*")
        machine.fail("findmnt -rn -S tank/imp")

    with subtest("it refuses a generation that does not exist, and changes nothing"):
        ctx = setup_case()
        machine.succeed("systemctl stop imp-host imp-docker-proxy")

        status, out = machine.execute(f"{restore} {copy} 99 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ["== check the copy", "== check the host"], out
        assert err.splitlines() == [
            "restore-impd-db: generation 99 does not exist",
            "restore-impd-db: nothing was changed",
        ], err
        machine.fail("ls -d /root/imp-db-backups/pre-restore-*")
        machine.fail("findmnt -rn -S tank/imp")

    with subtest("it refuses a generation that runs another image than the copy's, and changes nothing"):
        ctx = setup_case()
        machine.succeed("systemctl stop imp-host imp-docker-proxy")

        status, out = machine.execute(f"{restore} {copy} 3 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ["== check the copy", "== check the host"], out
        assert err.splitlines() == [
            "restore-impd-db: generation 3 runs ghcr.io/zgeoff/imp-host:0.29.0, but the copy is from ghcr.io/zgeoff/imp-host:0.28.0",
            "restore-impd-db: nothing was changed",
        ], err
        machine.fail("ls -d /root/imp-db-backups/pre-restore-*")
        machine.fail("findmnt -rn -S tank/imp")
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == base_path, f"the system is {current}"

    with subtest("it refuses while tank/imp is mounted, and changes nothing"):
        ctx = setup_case()
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")

        status, out = machine.execute(f"{restore} {copy} 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ["== check the copy", "== check the host"], out
        assert err.splitlines() == [
            "restore-impd-db: tank/imp is already mounted",
            "restore-impd-db: nothing was changed",
        ], err
        mounts = machine.succeed("findmnt -rn -S tank/imp -o TARGET").split()
        assert mounts == ["/mnt/imp"], f"tank/imp is mounted at {mounts}"
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        assert db_sums == ctx["db_sums"], f"the database changed: {db_sums}"
        machine.fail("ls -d /root/imp-db-backups/pre-restore-*")
  '';
}
