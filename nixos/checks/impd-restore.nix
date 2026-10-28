# A restore rehearsal for restore-impd-db (nixos/packages/impd-db-tools) in a NixOS VM: the
# machine, its reset and its boot subtests are test-utils/build-restore-rehearsal.nix's, and the
# VM has the packaged tools on PATH, as geoffcloud does. These subtests run the tool through the
# paths that real state reaches. Three run copy-impd-db-host as scripts/copy-impd-db.sh runs it
# on geoffcloud, against the real Podman and imp-host container, and one
# restores the copy it takes. The stand-in imp-host has no tank/imp mount, so those subtests
# write the database to its /var/lib/imp/db with podman cp.
#
# Stand-ins, from test-utils, beside the rehearsal's own: a sqlite3 that also holds the
# restore's mount busy (build-stub-sqlite3.nix), and one whose integrity_check gives the real
# report on a damaged index (build-stub-integrity-sqlite3.nix). Each subtest writes its own database, secret,
# copy and COPY-INFO, so every subtest stands alone. It needs KVM, and it reads test-support/shell
# beside nixos/, so it builds only from the repo root: run `bun run test:nixos impd-restore`.
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  stubSqlite3 = import ./test-utils/build-stub-sqlite3.nix { inherit pkgs; };
  stubIntegritySqlite3 = import ./test-utils/build-stub-integrity-sqlite3.nix { inherit pkgs; };
in
import ./test-utils/build-restore-rehearsal.nix { inherit nixpkgs imp; } {
  name = "impd-restore-rehearsal";
  subtests =
    { image28, image29 }:
    ''
      import re


      with subtest("it refuses to restore while imp-host runs, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image28.digestRef}")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ['== check the copy', '== check the host'], out
          assert err.splitlines() == ['restore-impd-db: imp-host is active, not stopped; run: systemctl stop imp-host', 'restore-impd-db: nothing was changed'], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          sums = read_database_sums()
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it refuses to restore while an imp-host container runs without its unit, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image28.digestRef}")
          machine.succeed("systemctl stop imp-host")
          machine.succeed("podman run -d --rm --name imp-host ${image29.ref} sleep infinity")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ['== check the copy', '== check the host'], out
          assert err.splitlines() == ['restore-impd-db: the imp-host container still runs; stop it before a restore', 'restore-impd-db: nothing was changed'], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          sums = read_database_sums()
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it restores the copy, saves the stopped database and switches to the copy's generation"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image28.digestRef}")
          machine.succeed("systemctl stop imp-host")

          before = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
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
          # switch-to-configuration's progress; the mounts Podman makes for imp-host (its network
          # namespace, its storage, its root file system and its /dev/shm) carry generated ids, and the
          # switch lists them, and imp-host.service when it starts imp-host itself, on one line
          err_lines = err.splitlines()
          mount_lines = [line for line in err_lines if line.startswith("the following new units were started: ")]
          assert len(mount_lines) <= 1 and all(re.fullmatch(r"the following new units were started: (((run-netns-netns(\\x2d[0-9a-f]+)+|var-lib-containers-storage-overlay|var-lib-containers-storage-overlay-[0-9a-f]{64}-merged|var-lib-containers-storage-overlay\\x2dcontainers-[0-9a-f]{64}-userdata-shm)\.mount|imp-host\.service)(, |$))+", line) for line in mount_lines), err
          assert [line for line in err_lines if line not in mount_lines] == [
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
          image = machine.succeed("podman inspect imp-host --format '{{.Config.Image}}'").strip()
          assert image == "${image28.digestRef}", image
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
          machine.succeed("systemctl stop imp-host")
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


      with subtest("it reads the migration from a COPY-INFO that names it migration, and its image by tag and digest"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
          machine.succeed(
              "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
          )
          # a copy from before imp #171 and from imp-host under Docker, which named the image as
          # the unit pins it
          machine.succeed(
              "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'migration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
          )
          machine.succeed("systemctl stop imp-host")

          before = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
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
          # switch-to-configuration's progress; the mounts Podman makes for imp-host (its network
          # namespace, its storage, its root file system and its /dev/shm) carry generated ids, and the
          # switch lists them, and imp-host.service when it starts imp-host itself, on one line
          err_lines = err.splitlines()
          mount_lines = [line for line in err_lines if line.startswith("the following new units were started: ")]
          assert len(mount_lines) <= 1 and all(re.fullmatch(r"the following new units were started: (((run-netns-netns(\\x2d[0-9a-f]+)+|var-lib-containers-storage-overlay|var-lib-containers-storage-overlay-[0-9a-f]{64}-merged|var-lib-containers-storage-overlay\\x2dcontainers-[0-9a-f]{64}-userdata-shm)\.mount|imp-host\.service)(, |$))+", line) for line in mount_lines), err
          assert [line for line in err_lines if line not in mount_lines] == [
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
          image = machine.succeed("podman inspect imp-host --format '{{.Config.Image}}'").strip()
          assert image == "${image28.digestRef}", image
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
          machine.succeed("systemctl stop imp-host")
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
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image29.digestRef}")
          machine.succeed("systemctl stop imp-host")

          before = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
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
          assert_generations_unchanged(ctx["base_path"])
          machine.succeed("systemctl is-active imp-host")
          image = machine.succeed("podman inspect imp-host --format '{{.Config.Image}}'").strip()
          assert image == "${image29.digestRef}", image
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
          machine.succeed("systemctl stop imp-host")
          machine.succeed("mount -t zfs tank/imp /mnt/imp")
          db_files = machine.succeed("ls -A /mnt/imp/db").split()
          published = machine.execute("cmp /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite /mnt/imp/db/imp.sqlite")[0]
          machine.succeed("umount /mnt/imp")
          assert db_files == ["imp.sqlite"], f"the database files are {db_files}"
          assert published == 0, "the published database differs from the copy"


      with subtest("it copies the database from the running imp-host, rows only in its WAL included, to a root-only copy that COPY-INFO describes"):
          ctx = setup_test()
          machine.succeed("install -d -m 0700 /tmp/impd-db-seed")
          machine.succeed(
              "sqlite3 /tmp/impd-db-seed/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
          )
          # the seed's marker table is only in its WAL: the main file alone has no such table
          main_tables = machine.succeed("sqlite3 'file:/tmp/impd-db-seed/imp.sqlite?immutable=1' \"SELECT count(*) FROM sqlite_schema WHERE name = 'marker';\"").strip()
          assert main_tables == "0", f"the seed's main file has {main_tables} marker tables"
          machine.succeed("podman exec imp-host mkdir -p /var/lib/imp/db")
          machine.succeed("podman cp /tmp/impd-db-seed/. imp-host:/var/lib/imp/db")

          before = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
          status, out = machine.execute("COPY_IMPD_DB_ALLOW_UNMOUNTED=1 copy-impd-db-host pre-0.30 2>/tmp/copy.err")
          after = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
          err = machine.succeed("cat /tmp/copy.err")

          assert status == 0, f"exit {status}: {out}{err}"
          assert err == "", err
          copies = machine.succeed("ls -d /root/imp-db-backups/pre-0.30-*").split()
          assert len(copies) == 1, f"the copies are {copies}"
          copy = copies[0]
          stamp = copy.removeprefix("/root/imp-db-backups/pre-0.30-")
          assert before <= stamp <= after, f"{stamp} is outside {before}..{after}"
          size = machine.succeed(f"stat -c %s {copy}/imp.sqlite").strip()
          lines = out.splitlines()
          created = lines[4].removeprefix("createdAt ") if len(lines) > 4 else ""
          assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", created), f"createdAt is {created!r}"
          created_stamp = created.replace("-", "").replace(":", "").removesuffix("Z")
          assert before <= created_stamp <= after, f"{created} is outside {before}..{after}"
          assert lines == [
              f"path {copy}/imp.sqlite",
              f"sizeBytes {size}",
              "lastMigration 0003_leases",
              "impVersion 0.29.0",
              f"createdAt {created}",
              "integrity ok",
              "image ${image29.digestRef}",
              f"copy: {copy} ({size} bytes, mode 600)",
          ], out
          info = machine.succeed(f"cat {copy}/COPY-INFO").splitlines()
          assert info == lines[:7], info
          listing = machine.succeed(f"cd {copy} && find . -printf '%M %u:%g %p\\n' | sort -k3").splitlines()
          assert listing == [
              "drwx------ root:root .",
              "-rw------- root:root ./COPY-INFO",
              "-rw------- root:root ./imp.sqlite",
          ], listing
          backups = machine.succeed("stat -c '%A %U:%G' /root/imp-db-backups").strip()
          assert backups == "drwx------ root:root", backups
          marker = machine.succeed(f"sqlite3 {copy}/imp.sqlite 'SELECT v FROM marker;'").strip()
          assert marker == "original", f"the copy's marker is {marker!r}"
          work = machine.succeed("podman exec imp-host ls -A /tmp")
          assert work == "", f"imp-host's /tmp holds {work}"


      with subtest("it restores a copy that copy-impd-db-host took, from the COPY-INFO it wrote"):
          ctx = setup_test()
          machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
          machine.succeed("install -d -m 0700 /mnt/imp/db")
          machine.succeed(
              "sqlite3 /mnt/imp/db/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t'),('0004_later','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('replaced');\""
          )
          machine.succeed("umount /mnt/imp")
          machine.succeed("install -d -m 0700 /tmp/impd-db-seed")
          machine.succeed(
              "sqlite3 /tmp/impd-db-seed/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
          )
          machine.succeed("podman exec imp-host mkdir -p /var/lib/imp/db")
          machine.succeed("podman cp /tmp/impd-db-seed/. imp-host:/var/lib/imp/db")
          machine.succeed("COPY_IMPD_DB_ALLOW_UNMOUNTED=1 copy-impd-db-host pre-0.30")
          copy = machine.succeed("ls -d /root/imp-db-backups/pre-0.30-*").strip()
          machine.succeed("systemctl stop imp-host")

          status, out = machine.execute(f"restore-impd-db {copy} 3 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 0, f"exit {status}: {out}{err}"
          assert err == "", err
          saved = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").strip()
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
              f"restored {copy} (migration 0003_leases) on generation 3; the replaced database is in {saved}",
          ], out
          machine.succeed("systemctl stop imp-host")
          machine.succeed("mount -t zfs tank/imp /mnt/imp")
          published = machine.execute(f"cmp {copy}/imp.sqlite /mnt/imp/db/imp.sqlite")[0]
          marker = machine.succeed("sqlite3 /mnt/imp/db/imp.sqlite 'SELECT v FROM marker;'").strip()
          machine.succeed("umount /mnt/imp")
          assert published == 0, "the published database differs from the copy"
          assert marker == "original", f"the published marker is {marker!r}"


      with subtest("it stops with podman's error, leaving only an empty copy directory, when imp-host is not running"):
          ctx = setup_test()
          # imp's module runs imp-host with --rm, so a stopped imp-host leaves no container
          machine.succeed("systemctl stop imp-host")

          status, out = machine.execute("COPY_IMPD_DB_ALLOW_UNMOUNTED=1 copy-impd-db-host pre-0.30 2>/tmp/copy.err")
          err = machine.succeed("cat /tmp/copy.err")

          # podman exec's own status for an exec it could not start
          assert status == 125, f"exit {status}: {out}{err}"
          assert out == "", out
          assert err.splitlines() == ['Error: no container with name or ID "imp-host" found: no such container'], err
          left = machine.succeed("find /root/imp-db-backups -mindepth 1 -printf '%M %P\\n'").splitlines()
          assert len(left) == 1, f"the backups hold {left}"
          assert re.fullmatch(r"drwx------ pre-0\.30-\d{8}T\d{6}", left[0]), f"the backups hold {left}"


      with subtest("it exits 1 with the whole report, its integrity findings on one line, when the copy fails integrity_check"):
          ctx = setup_test()
          machine.succeed("install -d -m 0700 /tmp/impd-db-seed")
          machine.succeed(
              "sqlite3 /tmp/impd-db-seed/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\""
          )
          machine.succeed("podman exec imp-host mkdir -p /var/lib/imp/db")
          machine.succeed("podman cp /tmp/impd-db-seed/. imp-host:/var/lib/imp/db")

          status, out = machine.execute("COPY_IMPD_DB_ALLOW_UNMOUNTED=1 SQLITE3=${stubIntegritySqlite3} copy-impd-db-host pre-0.30 2>/tmp/copy.err")
          err = machine.succeed("cat /tmp/copy.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert err == "", err
          copy = machine.succeed("ls -d /root/imp-db-backups/pre-0.30-*").strip()
          size = machine.succeed(f"stat -c %s {copy}/imp.sqlite").strip()
          lines = out.splitlines()
          created = lines[4].removeprefix("createdAt ") if len(lines) > 4 else ""
          assert lines == [
              f"path {copy}/imp.sqlite",
              f"sizeBytes {size}",
              "lastMigration 0003_leases",
              "impVersion 0.29.0",
              f"createdAt {created}",
              "integrity wrong # of entries in index sqlite_autoindex_imps_1; row 1 missing from index sqlite_autoindex_imps_1; row 2 missing from index sqlite_autoindex_imps_1; row 3 missing from index sqlite_autoindex_imps_1",
              "image ${image29.digestRef}",
              f"copy: {copy} ({size} bytes, mode 600)",
          ], out
          info = machine.succeed(f"cat {copy}/COPY-INFO").splitlines()
          assert info == lines[:7], info
          work = machine.succeed("podman exec imp-host ls -A /tmp")
          assert work == "", f"imp-host's /tmp holds {work}"


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
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image29.digestRef}")
          machine.succeed("systemctl stop imp-host")

          before = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
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
          assert_generations_unchanged(ctx["base_path"])
          machine.succeed("systemctl is-active imp-host")
          image = machine.succeed("podman inspect imp-host --format '{{.Config.Image}}'").strip()
          assert image == "${image29.digestRef}", image
          listing = machine.succeed(f"cd {saved} && find . -printf '%M %u:%g %p\\n' | sort -k3").splitlines()
          assert listing == [
              "drwx------ root:root .",
              "-rw------- root:root ./imp.sqlite",
              "drwx------ root:root ./secrets",
              "-rw------- root:root ./secrets/glm",
          ], listing
          saved_sums = machine.succeed(f"cd {saved} && sha256sum imp.sqlite")
          assert saved_sums == db_sums, f"the saved database differs: {saved_sums}"
          machine.succeed("systemctl stop imp-host")
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
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image29.digestRef}")
          machine.succeed("systemctl stop imp-host")

          before = machine.succeed("date -u +%Y%m%dT%H%M%S").strip()
          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
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
          assert_generations_unchanged(ctx["base_path"])
          machine.succeed("systemctl is-active imp-host")
          image = machine.succeed("podman inspect imp-host --format '{{.Config.Image}}'").strip()
          assert image == "${image29.digestRef}", image
          listing = machine.succeed(f"cd {saved} && find . -printf '%M %u:%g %p\\n' | sort -k3").splitlines()
          assert listing == [
              "drwx------ root:root .",
              "-rw------- root:root ./imp.sqlite",
              "-rw------- root:root ./imp.sqlite-shm",
              "-rw------- root:root ./imp.sqlite-wal",
          ], listing
          saved_sums = machine.succeed(f"cd {saved} && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
          assert saved_sums == db_sums, f"the saved database differs: {saved_sums}"
          machine.succeed("systemctl stop imp-host")
          machine.succeed("mount -t zfs tank/imp /mnt/imp")
          db_files = machine.succeed("ls -A /mnt/imp/db").split()
          published = machine.execute("cmp /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite /mnt/imp/db/imp.sqlite")[0]
          machine.succeed("umount /mnt/imp")
          assert db_files == ["imp.sqlite"], f"the database files are {db_files}"
          assert published == 0, "the published database differs from the copy"


      with subtest("it prints its usage, and changes nothing, without arguments"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image28.digestRef}")
          machine.succeed("systemctl stop imp-host")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          tool = machine.succeed("command -v restore-impd-db").strip()
          status, out = machine.execute("restore-impd-db 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out == "", out
          # bash names the tool as PATH found it and the line of the failed expansion, the
          # script's first argument, in the file writeShellApplication wrote
          assert err == f"{tool}: line 28: 1: usage: restore-impd-db /root/imp-db-backups/<copy> <generation>\n", err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          sums = read_database_sums()
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it refuses a copy without imp.sqlite, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
          machine.succeed(
              "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' 'sizeBytes 0' 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.digestRef}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
          )
          machine.succeed("systemctl stop imp-host")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ['== check the copy'], out
          assert err.splitlines() == ['restore-impd-db: /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite is missing', 'restore-impd-db: nothing was changed'], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          sums = read_database_sums()
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it refuses a copy that fails integrity_check, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
          machine.succeed("printf 'not a database\\n' > /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite")
          machine.succeed(
              "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.digestRef}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
          )
          machine.succeed("systemctl stop imp-host")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ['== check the copy'], out
          assert err.splitlines() == ['Error: in prepare, file is not a database (26)', 'restore-impd-db: the copy fails integrity_check', 'restore-impd-db: nothing was changed'], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          sums = read_database_sums()
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it refuses a copy without COPY-INFO, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
          machine.succeed(
              "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
          )
          machine.succeed("systemctl stop imp-host")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ['== check the copy'], out
          assert err.splitlines() == ['restore-impd-db: /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO is missing; only a copy-impd-db.sh copy is restorable', 'restore-impd-db: nothing was changed'], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          sums = read_database_sums()
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it refuses a COPY-INFO without an image, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
          machine.succeed(
              "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
          )
          machine.succeed(
              "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
          )
          machine.succeed("systemctl stop imp-host")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ['== check the copy'], out
          assert err.splitlines() == ['restore-impd-db: COPY-INFO lacks the image or the migration', 'restore-impd-db: nothing was changed'], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          sums = read_database_sums()
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it refuses a COPY-INFO without a migration, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
          machine.succeed(
              "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
          )
          machine.succeed(
              "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.digestRef}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
          )
          machine.succeed("systemctl stop imp-host")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ['== check the copy'], out
          assert err.splitlines() == ['restore-impd-db: COPY-INFO lacks the image or the migration', 'restore-impd-db: nothing was changed'], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          sums = read_database_sums()
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it refuses a copy whose newest migration differs from COPY-INFO, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
          machine.succeed(
              "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
          )
          machine.succeed(
              "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0003_leases' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.digestRef}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
          )
          machine.succeed("systemctl stop imp-host")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ['== check the copy'], out
          assert err.splitlines() == ["restore-impd-db: the copy's newest migration differs from COPY-INFO", 'restore-impd-db: nothing was changed'], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          sums = read_database_sums()
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it refuses a generation that is not a number, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image28.digestRef}")
          machine.succeed("systemctl stop imp-host")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 old 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ['== check the copy', '== check the host'], out
          assert err.splitlines() == ['restore-impd-db: the generation must be a number, such as 14', 'restore-impd-db: nothing was changed'], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          sums = read_database_sums()
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it refuses a generation that does not exist, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image28.digestRef}")
          machine.succeed("systemctl stop imp-host")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 99 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ['== check the copy', '== check the host'], out
          assert err.splitlines() == ['restore-impd-db: generation 99 does not exist', 'restore-impd-db: nothing was changed'], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          sums = read_database_sums()
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it refuses a generation that runs another image than the copy's, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image28.digestRef}")
          machine.succeed("systemctl stop imp-host")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ['== check the copy', '== check the host'], out
          assert err.splitlines() == ['restore-impd-db: generation 3 runs ${image29.ref}, but the copy is from ${image28.digestRef}', 'restore-impd-db: nothing was changed'], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          sums = read_database_sums()
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it refuses a generation whose imp-host runs without Podman, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image29.digestRef}")
          machine.succeed("systemctl stop imp-host")
          # generation 4 runs the copy's image under Docker, as imp before 6.0.0 did; the profile
          # stays on generation 3
          docker_path = machine.succeed(f"readlink -f {ctx['base_path']}/specialisation/docker").strip()
          machine.succeed(f"ln -s {docker_path} /nix/var/nix/profiles/system-4-link")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 4 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ['== check the copy', '== check the host'], out
          assert err.splitlines() == ['restore-impd-db: generation 4 runs imp-host without Podman; restore only to a generation of imp 6.0.0 or later', 'restore-impd-db: nothing was changed'], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
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
          assert links == ["system-1-link", "system-2-link", "system-3-link", "system-4-link"], f"the generations are {links}"
          sums = read_database_sums()
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it refuses while tank/imp is mounted, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image28.digestRef}")
          machine.succeed("systemctl stop imp-host")
          machine.succeed("mount -t zfs tank/imp /mnt/imp")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ['== check the copy', '== check the host'], out
          assert err.splitlines() == ['restore-impd-db: tank/imp is already mounted', 'restore-impd-db: nothing was changed'], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          mounts = machine.succeed("findmnt -rn -S tank/imp -o TARGET").split()
          assert mounts == ["/mnt/imp"], f"tank/imp is mounted at {mounts}"
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
          machine.succeed("umount /mnt/imp")
          assert sums == db_sums, f"the database changed: {sums}"


      with subtest("it refuses a dataset without imp.sqlite, and changes nothing"):
          ctx = setup_test()
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image28.digestRef}")
          machine.succeed("systemctl stop imp-host")
          machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
          dataset_before = machine.succeed("cd /mnt/imp && find . | sort")
          machine.succeed("umount /mnt/imp")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ["== check the copy", "== check the host", "== mount tank/imp"], out
          err_lines = err.splitlines()
          assert len(err_lines) == 2, err
          # the mountpoint is a fresh mktemp directory
          assert re.fullmatch(r"restore-impd-db: /run/impd-restore\.\w{6}/db/imp\.sqlite is missing; is tank/imp impd's dataset\?", err_lines[0]), err
          assert err_lines[1] == "restore-impd-db: nothing was changed", err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          machine.succeed("mount -t zfs tank/imp /mnt/imp")
          dataset_after = machine.succeed("cd /mnt/imp && find . | sort")
          machine.succeed("umount /mnt/imp")
          assert dataset_after == dataset_before, f"the dataset changed: {dataset_after}"


      with subtest("it refuses to restore when podman cannot list the containers, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image28.digestRef}")
          machine.succeed("systemctl stop imp-host")
          # podman reads its config from CONTAINERS_CONF in place of /etc/containers, and stops on
          # one that is not TOML
          machine.succeed("printf '[engine\\n' > /tmp/broken-containers.conf")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("CONTAINERS_CONF=/tmp/broken-containers.conf restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ["== check the copy", "== check the host"], out
          # podman's own error comes first; the TOML parser's detail after "toml: " is not ours
          err_lines = err.splitlines()
          assert err_lines[0].startswith('Failed to obtain podman configuration: reading system config "/tmp/broken-containers.conf": decode configuration /tmp/broken-containers.conf: toml: '), err
          assert err_lines[1:] == [
              "restore-impd-db: cannot list podman containers",
              "restore-impd-db: nothing was changed",
          ], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          backups = machine.succeed("ls -A /root/imp-db-backups").split()
          assert backups == ["pre-0.29-20261004T000000"], f"the backups are {backups}"
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          assert_generations_unchanged(ctx["base_path"])
          machine.succeed("mount -t zfs tank/imp /mnt/imp")
          sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
          db_files = machine.succeed("ls -A /mnt/imp/db").split()
          machine.succeed("umount /mnt/imp")
          assert sums == db_sums, f"the database changed: {sums}"
          assert db_files == ['imp.sqlite', 'imp.sqlite-shm', 'imp.sqlite-wal'], f"the database files are {db_files}"


      with subtest("it stops, and leaves the database in place, when the staged file fails integrity_check"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
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
              "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image29.digestRef}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
          )
          machine.succeed("mount --bind /root/imp-db-backups/pre-0.29-20261004T000000 /root/imp-db-backups/pre-0.29-20261004T000000 && mount -o remount,ro,bind /root/imp-db-backups/pre-0.29-20261004T000000")
          machine.succeed("systemctl stop imp-host")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
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
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          assert_generations_unchanged(ctx["base_path"])
          machine.succeed("mount -t zfs tank/imp /mnt/imp")
          sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
          db_files = machine.succeed("ls -A /mnt/imp/db").split()
          machine.succeed("umount /mnt/imp")
          assert sums == db_sums, f"the database changed: {sums}"
          assert db_files == ['imp.sqlite', 'imp.sqlite-shm', 'imp.sqlite-wal'], f"the database files are {db_files}"


      with subtest("it warns that tank/imp is still mounted when it stops and cannot unmount it"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
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
              "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image29.digestRef}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
          )
          machine.succeed("mount --bind /root/imp-db-backups/pre-0.29-20261004T000000 /root/imp-db-backups/pre-0.29-20261004T000000 && mount -o remount,ro,bind /root/imp-db-backups/pre-0.29-20261004T000000")
          machine.succeed("systemctl stop imp-host")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("SQLITE3=${stubSqlite3} HOLDER_PID_FILE=/tmp/holder.pid restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
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
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          assert_generations_unchanged(ctx["base_path"])
          sums = machine.succeed(f"cd {mounts[0]}/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
          db_files = machine.succeed(f"ls -A {mounts[0]}/db").split()
          assert sums == db_sums, f"the database changed: {sums}"
          assert db_files == ["imp.sqlite", "imp.sqlite-shm", "imp.sqlite-wal"], f"the database files are {db_files}"


      with subtest("it stops, leaving the copy in place and tank/imp mounted, when it cannot unmount tank/imp"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image29.digestRef}")
          machine.succeed("systemctl stop imp-host")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host").split()

          status, out = machine.execute("SQLITE3=${stubSqlite3} HOLDER_PID_FILE=/tmp/holder.pid restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
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
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          assert_generations_unchanged(ctx["base_path"])
          published = machine.execute(f"cmp /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite {mounts[0]}/db/imp.sqlite")[0]
          db_files = machine.succeed(f"ls -A {mounts[0]}/db").split()
          assert published == 0, "the published database differs from the copy"
          assert db_files == ["imp.sqlite"], f"the database files are {db_files}"


      with subtest("it stops imp-host again when it comes up on another image than the copy's"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image28.digestRef}")
          machine.succeed("systemctl stop imp-host")
          # /run/current-system names generation 1 (0.28.0) while the loaded units stay generation
          # 3's (0.29.0): the script takes generation 1 as running, skips the switch, and starts
          # 0.29.0's imp-host
          machine.succeed(f"ln -sfn {ctx['old_path']} /run/current-system")

          status, out = machine.execute("restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
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
              "restore-impd-db: imp-host runs ${image29.digestRef}, not the copy's ${image28.digestRef}",
              f"restore-impd-db: the copy is in place (the original is in {saved}); "
              "the switch or start did not finish; imp-host is stopped again",
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
          units = machine.succeed("systemctl show -p ActiveState --value imp-host").split()
          # a stop leaves imp-host under Podman inactive in some runs and failed in others
          assert units in (["inactive"], ["failed"]), f"the units are {units}"
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
