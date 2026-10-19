# The restore rehearsal's boundary subtests for restore-impd-db, in a NixOS VM: the
# machine, its reset and its boot subtests are test-utils/build-restore-rehearsal.nix's, the same
# as impd-restore's. These subtests reach the errors that no real state on the machine can
# trigger, through the script's SYSTEMCTL and CMP: each puts one stand-in in place of the real
# command, and the stand-in passes every call but one through to it.
#
# Stand-ins, from test-utils, beside the rehearsal's own: a systemctl that cannot read one
# unit's state (build-stub-systemctl.nix), and a cmp that finds one comparison different
# (build-stub-cmp.nix). Each subtest writes its own database, secret, copy and COPY-INFO, so
# every subtest stands alone. It needs KVM, and it reads test-support/shell beside nixos/, so it
# builds only from the repo root: run `bun run test:nixos impd-restore-boundaries`.
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  stubSystemctl = import ./test-utils/build-stub-systemctl.nix { inherit pkgs; };
  stubCmp = import ./test-utils/build-stub-cmp.nix { inherit pkgs; };
in
import ./test-utils/build-restore-rehearsal.nix { inherit nixpkgs imp; } {
  name = "impd-restore-boundaries-rehearsal";
  subtests =
    { image28, image29 }:
    ''
      with subtest("it refuses to restore when it cannot read a unit's state, and changes nothing"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image28.ref}")
          machine.succeed("systemctl stop imp-host imp-docker-proxy")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

          status, out = machine.execute("SYSTEMCTL=${stubSystemctl} FAIL_SHOW_UNIT=imp-docker-proxy restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 1 2>/tmp/restore.err")
          err = machine.succeed("cat /tmp/restore.err")

          assert status == 1, f"exit {status}: {out}{err}"
          assert out.splitlines() == ["== check the copy", "== check the host"], out
          # imp-host's state read passes through the stand-in; imp-docker-proxy's fails
          assert err.splitlines() == [
              "Failed to get properties: Connection timed out",
              "restore-impd-db: cannot read imp-docker-proxy's state",
              "restore-impd-db: nothing was changed",
          ], err
          units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
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


      with subtest("it stops, and leaves the database in place, when the staged file differs from the copy"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image29.ref}")
          machine.succeed("systemctl stop imp-host imp-docker-proxy")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

          status, out = machine.execute("CMP=${stubCmp} FAIL_CMP_FIRST=/root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite FAIL_CMP_SECOND='/run/impd-restore.*/db/imp.sqlite.restore' restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
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
          ], out
          assert err.splitlines() == [
              "restore-impd-db: the staged file differs from the copy",
              f"restore-impd-db: the original database is saved in {saved}; nothing was started or switched",
          ], err
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          assert_generations_unchanged(ctx["base_path"])
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
          machine.succeed("mount -t zfs tank/imp /mnt/imp")
          sums = machine.succeed("cd /mnt/imp/db && sha256sum imp.sqlite imp.sqlite-shm imp.sqlite-wal")
          # the staged file is removed on the way out
          db_files = machine.succeed("ls -A /mnt/imp/db").split()
          secret = machine.succeed("cat /mnt/imp/secrets/glm")
          secret_saved = machine.execute(f"cmp /mnt/imp/secrets/glm {saved}/secrets/glm")[0]
          machine.succeed("umount /mnt/imp")
          assert sums == db_sums, f"the database changed: {sums}"
          assert db_files == ['imp.sqlite', 'imp.sqlite-shm', 'imp.sqlite-wal'], f"the database files are {db_files}"
          assert secret == "dummy-secret-value\n", f"the secret reads {secret!r}"
          assert secret_saved == 0, "the saved secret differs from the one in place"


      with subtest("it stops, leaving the copy in place and tank/imp unmounted, when the published database differs from the copy"):
          ctx = setup_test()
          db_sums = write_dataset(["0001_init", "0002_tokens", "0003_leases"], "original", "dummy-secret-value")
          write_copy("/root/imp-db-backups/pre-0.29-20261004T000000", ["0001_init", "0002_tokens"], "copy", "${image29.ref}")
          machine.succeed("systemctl stop imp-host imp-docker-proxy")
          units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()

          status, out = machine.execute("CMP=${stubCmp} FAIL_CMP_FIRST=/root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite FAIL_CMP_SECOND='/run/impd-restore.*/db/imp.sqlite' restore-impd-db /root/imp-db-backups/pre-0.29-20261004T000000 3 2>/tmp/restore.err")
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
          ], out
          # the script records that the copy is in place only after this check, so its last line
          # still reads as before the publish
          assert err.splitlines() == [
              "restore-impd-db: the published database differs from the copy",
              f"restore-impd-db: the original database is saved in {saved}; nothing was started or switched",
          ], err
          machine.fail("findmnt -rn -S tank/imp")
          leftovers = machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*'")
          assert leftovers == "", f"the script left {leftovers}"
          units = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
          assert units == units_before, f"the units went from {units_before} to {units}"
          assert_generations_unchanged(ctx["base_path"])
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

    '';
}
