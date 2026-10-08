# A restore rehearsal for scripts/restore-impd-db.sh in a NixOS VM: the machine, its reset and
# its boot subtests are test-utils/build-restore-rehearsal.nix's. These subtests run the script
# through the paths that real state reaches.
#
# Stand-ins, from test-utils, beside the rehearsal's own: a sqlite3 that also holds the
# restore's mount busy (build-stub-sqlite3.nix). Each subtest writes its own database, secret,
# copy and COPY-INFO, so every subtest stands alone. It needs KVM, and it reads scripts/ beside
# nixos/, so it builds only from the repo root: run `bun run test:nixos impd-restore`.
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  stubSqlite3 = import ./test-utils/build-stub-sqlite3.nix { inherit pkgs; };
in
import ./test-utils/build-restore-rehearsal.nix { inherit nixpkgs imp; } {
  name = "impd-restore-rehearsal";
  subtests =
    { image28, image29 }:
    ''
    import re


    with subtest("it refuses to restore while imp-host runs, and changes nothing"):
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("docker run -d --rm --name imp-host ${image29.ref} sleep infinity")
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


    with subtest("it restores the copy, saves the stopped database and switches to the copy's generation"):
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        # switch-to-configuration's progress; the mounts docker made for imp-host carry generated
        # ids, and how many it made varies
        err_lines = err.splitlines()
        assert re.fullmatch(r"the following new units were started: ((run-docker-netns-[0-9a-f]+|tmp-containerd\\x2dmount[0-9]+|var-lib-docker-rootfs-overlayfs-[0-9a-f]+)\.mount(, |$))+", err_lines[5]), err
        assert err_lines[:5] + err_lines[6:] == [
            "Checking switch inhibitors... done",
            "updating GRUB 2 menu...",
            "activating the configuration...",
            "restarting sysinit-reactivation.target",
            "reloading the following units: dbus-broker.service",
        ], err
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
        assert image == "${image28.ref}", image
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
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'migration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        # switch-to-configuration's progress; the mounts docker made for imp-host carry generated
        # ids, and how many it made varies
        err_lines = err.splitlines()
        assert re.fullmatch(r"the following new units were started: ((run-docker-netns-[0-9a-f]+|tmp-containerd\\x2dmount[0-9]+|var-lib-docker-rootfs-overlayfs-[0-9a-f]+)\.mount(, |$))+", err_lines[5]), err
        assert err_lines[:5] + err_lines[6:] == [
            "Checking switch inhibitors... done",
            "updating GRUB 2 menu...",
            "activating the configuration...",
            "restarting sysinit-reactivation.target",
            "reloading the following units: dbus-broker.service",
        ], err
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
        assert image == "${image28.ref}", image
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


    with subtest("it restores without a switch when the copy's generation is the running one"):
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image29.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        assert image == "${image29.ref}", image
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
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image29.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        assert image == "${image29.ref}", image
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
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image29.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        assert image == "${image29.ref}", image
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


    with subtest("it prints its usage, and changes nothing, without arguments"):
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh}  2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out == "", out
        # bash names the script and the line of the failed expansion, the script's first argument
        assert err == "${../../scripts/restore-impd-db.sh}: line 20: 1: usage: restore-impd-db.sh /root/imp-db-backups/<copy> <generation>\n", err
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
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' 'sizeBytes 0' 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        ctx = setup_test()
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
        ctx = setup_test()
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
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0003_leases' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ['== check the copy', '== check the host'], out
        assert err.splitlines() == ['restore-impd-db: generation 3 runs ${image29.ref}, but the copy is from ${image28.ref}', 'restore-impd-db: nothing was changed'], err
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
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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
        ctx = setup_test()
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
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


    with subtest("it refuses to restore when docker does not answer, and changes nothing"):
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("systemctl stop docker.socket docker.service")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        assert out.splitlines() == ["== check the copy", "== check the host"], out
        assert err.splitlines() == [
            "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?",
            "restore-impd-db: cannot list docker containers",
            "restore-impd-db: nothing was changed",
        ], err
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
        db_files = machine.succeed("ls -A /mnt/imp/db").split()
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"
        assert db_files == ['imp.sqlite', 'imp.sqlite-shm', 'imp.sqlite-wal'], f"the database files are {db_files}"


    with subtest("it stops, and leaves the database in place, when the staged file fails integrity_check"):
        ctx = setup_test()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        # a copy whose newest marker page is only in its WAL, over a damaged page in the main
        # file: read with its WAL it is sound, and the main file alone, which is all the script
        # stages, is not. The copy is mounted read-only, so no read checkpoints the WAL into it.
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy, first');\""
        )
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' \"UPDATE marker SET v = 'copy';\""
        )
        machine.succeed(
            "root=$(sqlite3 'file:/root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite?mode=ro&immutable=1' \"SELECT rootpage FROM sqlite_master WHERE name = 'marker';\") && head -c 4096 /dev/zero | tr '\\0' 'x' | dd of=/root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite bs=4096 seek=$((root - 1)) count=1 conv=notrunc status=none"
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image29.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("mount --bind /root/imp-db-backups/pre-0.29-20261004T000000 /root/imp-db-backups/pre-0.29-20261004T000000 && mount -o remount,ro,bind /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        saved_dirs = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").split()
        assert len(saved_dirs) == 1, f"the saved directories are {saved_dirs}"
        saved = saved_dirs[0]
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        assert out.splitlines() == [
            "== check the copy",
            "== check the host",
            "== mount tank/imp",
            "== preserve the stopped database",
            f"saved: {saved}",
            "== stage and check the copy",
        ], out
        assert err.splitlines() == [
            "Error: stepping, database disk image is malformed (11)",
            "restore-impd-db: the staged file fails integrity_check",
            f"restore-impd-db: the original database is saved in {saved}; nothing was started or switched",
        ], err
        # the stopped database and its secrets, saved before anything changed
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
        saved_secret = machine.succeed(f"cat {saved}/secrets/glm")
        assert saved_secret == "dummy-secret-value\n", f"the saved secret reads {saved_secret!r}"
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        db_files = machine.succeed("ls -A /mnt/imp/db").split()
        machine.succeed("umount /mnt/imp")
        assert sums == db_sums, f"the database changed: {sums}"
        assert db_files == ['imp.sqlite', 'imp.sqlite-shm', 'imp.sqlite-wal'], f"the database files are {db_files}"


    with subtest("it warns that tank/imp is still mounted when it stops and cannot unmount it"):
        ctx = setup_test()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        db_sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        machine.succeed("umount /mnt/imp")
        # a copy whose newest marker page is only in its WAL, over a damaged page in the main
        # file: read with its WAL it is sound, and the main file alone, which is all the script
        # stages, is not. The copy is mounted read-only, so no read checkpoints the WAL into it.
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy, first');\""
        )
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' \"UPDATE marker SET v = 'copy';\""
        )
        machine.succeed(
            "root=$(sqlite3 'file:/root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite?mode=ro&immutable=1' \"SELECT rootpage FROM sqlite_master WHERE name = 'marker';\") && head -c 4096 /dev/zero | tr '\\0' 'x' | dd of=/root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite bs=4096 seek=$((root - 1)) count=1 conv=notrunc status=none"
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image29.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("mount --bind /root/imp-db-backups/pre-0.29-20261004T000000 /root/imp-db-backups/pre-0.29-20261004T000000 && mount -o remount,ro,bind /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=${stubSqlite3} HOLDER_PID_FILE=/tmp/holder.pid bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        saved_dirs = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").split()
        assert len(saved_dirs) == 1, f"the saved directories are {saved_dirs}"
        saved = saved_dirs[0]
        # the holder keeps the mount busy
        mounts = machine.succeed("findmnt -rn -S tank/imp -o TARGET").split()
        assert len(mounts) == 1, f"tank/imp is mounted at {mounts}"
        assert re.fullmatch(r"/run/impd-restore\.\w{6}", mounts[0]), f"tank/imp is mounted at {mounts[0]!r}, not a /run/impd-restore.* directory"
        assert out.splitlines() == [
            "== check the copy",
            "== check the host",
            "== mount tank/imp",
            "== preserve the stopped database",
            f"saved: {saved}",
            "== stage and check the copy",
        ], out
        assert err.splitlines() == [
            "Error: stepping, database disk image is malformed (11)",
            "restore-impd-db: the staged file fails integrity_check",
            f"restore-impd-db: the original database is saved in {saved}; nothing was started or switched",
            f"umount: {mounts[0]}: target is busy.",
            f"restore-impd-db: tank/imp is still mounted at {mounts[0]}; unmount it by hand",
        ], err
        # the stopped database and its secrets, saved before anything changed
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
        saved_secret = machine.succeed(f"cat {saved}/secrets/glm")
        assert saved_secret == "dummy-secret-value\n", f"the saved secret reads {saved_secret!r}"
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        sums = machine.succeed(f"cd {mounts[0]}/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
        db_files = machine.succeed(f"ls -A {mounts[0]}/db").split()
        assert sums == db_sums, f"the database changed: {sums}"
        assert db_files == ["imp.sqlite", "imp.sqlite-shm", "imp.sqlite-wal"], f"the database files are {db_files}"


    with subtest("it stops, leaving the copy in place and tank/imp mounted, when it cannot unmount tank/imp"):
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image29.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

        status, out = machine.execute("SQLITE3=${stubSqlite3} HOLDER_PID_FILE=/tmp/holder.pid bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

        assert status == 1, f"exit {status}: {out}{err}"
        saved_dirs = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").split()
        assert len(saved_dirs) == 1, f"the saved directories are {saved_dirs}"
        saved = saved_dirs[0]
        mounts = machine.succeed("findmnt -rn -S tank/imp -o TARGET").split()
        assert len(mounts) == 1, f"tank/imp is mounted at {mounts}"
        assert re.fullmatch(r"/run/impd-restore\.\w{6}", mounts[0]), f"tank/imp is mounted at {mounts[0]!r}, not a /run/impd-restore.* directory"
        assert out.splitlines() == [
            "== check the copy",
            "== check the host",
            "== mount tank/imp",
            "== preserve the stopped database",
            f"saved: {saved}",
            "== stage and check the copy",
            "== publish",
            "== unmount",
        ], out
        assert err.splitlines() == [
            f"umount: {mounts[0]}: target is busy.",
            f"restore-impd-db: cannot unmount {mounts[0]}",
            f"restore-impd-db: the copy is in place (the original is in {saved}); nothing was started or switched",
        ], err
        # the stopped database and its secrets, saved before anything changed
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
        saved_secret = machine.succeed(f"cat {saved}/secrets/glm")
        assert saved_secret == "dummy-secret-value\n", f"the saved secret reads {saved_secret!r}"
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == units_before, f"the units went from {units_before} to {units}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == ctx["base_path"], f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        published = machine.execute(f"cmp /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite {mounts[0]}/db/imp.sqlite")[0]
        db_files = machine.succeed(f"ls -A {mounts[0]}/db").split()
        assert published == 0, "the published database differs from the copy"
        assert db_files == ["imp.sqlite"], f"the database files are {db_files}"


    with subtest("it stops both units again when imp-host comes up on another image than the copy's"):
        ctx = setup_test()
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
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        # /run/current-system names generation 1 (0.28.0) while the loaded units stay generation
        # 3's (0.29.0): the script takes generation 1 as running, skips the switch, and starts
        # 0.29.0's imp-host
        machine.succeed(f"ln -sfn {ctx['old_path']} /run/current-system")

        status, out = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
        err = machine.succeed("cat /tmp/restore.err")

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
            "== activate generation 1",
            "== start",
        ], out
        assert err.splitlines() == [
            "restore-impd-db: imp-host runs ${image29.ref}, not the copy's ${image28.ref}",
            f"restore-impd-db: the copy is in place (the original is in {saved}); "
            "the switch or start did not finish; imp-host and imp-docker-proxy are stopped again",
        ], err
        # the stopped database and its secrets, saved before anything changed
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
        saved_secret = machine.succeed(f"cat {saved}/secrets/glm")
        assert saved_secret == "dummy-secret-value\n", f"the saved secret reads {saved_secret!r}"
        units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        assert units == ["failed", "failed"], f"the units are {units}"
        machine.fail("findmnt -rn -S tank/imp")
        leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
        assert leftovers == "", f"the script left {leftovers}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        published = machine.execute("cmp /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite /mnt/imp/db/imp.sqlite")[0]
        machine.succeed("umount /mnt/imp")
        assert published == 0, "the published database differs from the copy"

    '';
}
