# Checks the restore rehearsal's reset, setup_test() in test-utils/build-restore-rehearsal.nix,
# on the rehearsal's own machine. Each subtest starts from the reset, leaves one kind of state
# that a rehearsal subtest can leave, runs the reset again, and checks the whole boot state the
# reset promises: the booted 0.29.0 system current; generations 1 (0.28.0), 2 (0.28.0, a switch
# that fails) and 3 (the booted one) in the system profile, and returned as the reset's three
# paths; no unit failed; docker and both imp units up; imp-host and its proxy the only
# containers, imp-host on its image, and that image the only one; an empty tank/imp with no
# snapshot or child, mounted nowhere; nothing mounted under the backups or over imp-host's
# seccomp profile; and no holder, backup, restore error, pause log or restore directory left.
#
# Beside the hand-made states, the last subtests reach the reset from what a real run leaves: a
# restore-impd-db.sh run that fails in its switch, and one killed with SIGKILL while it checks its
# staged copy, so its EXIT trap never unmounts tank/imp. A stand-in sqlite3 from test-utils
# (build-stub-blocking-sqlite3.nix) blocks in that check and names itself in /tmp/holder.pid,
# which is the test's signal to kill the script; the reset then ends the stand-in as it ends any
# holder. The last two take the reset's own steps up to a point where an earlier reset could have
# stopped: tank/imp destroyed and not yet made again, and every system profile link removed. It
# needs KVM, and it reads scripts/ beside nixos/, so it builds only from the repo root: run
# `bun run test:nixos impd-restore-reset`.
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  stubBlockingSqlite3 = import ./test-utils/build-stub-blocking-sqlite3.nix { inherit pkgs; };
in
import ./test-utils/build-restore-rehearsal.nix { inherit nixpkgs imp; } {
  name = "impd-restore-reset-rehearsal";
  subtests =
    { image28, image29 }:
    ''
    import re


    with subtest("it ends the holder that keeps tank/imp busy, and unmounts tank/imp"):
        ctx = setup_test()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("cd /mnt/imp && { sleep infinity < /dev/null > /dev/null 2>&1 & echo $! > /tmp/holder.pid; }")
        holder = machine.succeed("cat /tmp/holder.pid").strip()
        busy_before = machine.execute("umount /mnt/imp")[0]

        ctx = setup_test()
        assert busy_before == 32, f"umount of the held mount exited {busy_before}"
        machine.fail(f"kill -0 {holder}")
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it unmounts tank/imp from every place it is mounted"):
        ctx = setup_test()
        machine.succeed("mkdir -p /mnt/imp /mnt/imp-again && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("mount --bind /mnt/imp /mnt/imp-again")
        mounts_before = sorted(machine.succeed("findmnt -rn -S tank/imp -o TARGET").split())

        ctx = setup_test()
        assert mounts_before == ["/mnt/imp", "/mnt/imp-again"], f"tank/imp was mounted on {mounts_before}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it unmounts what is mounted under the backups, the inner mount first"):
        ctx = setup_test()
        machine.succeed("mkdir -p /root/imp-db-backups/copy && mount -t tmpfs copy /root/imp-db-backups/copy")
        machine.succeed("mkdir /root/imp-db-backups/copy/inner && mount -t tmpfs inner /root/imp-db-backups/copy/inner")
        targets_before = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts_before = [target for target in targets_before if target.startswith("/root/imp-db-backups")]

        ctx = setup_test()
        assert backup_mounts_before == ["/root/imp-db-backups/copy", "/root/imp-db-backups/copy/inner"], f"mounted under the backups were {backup_mounts_before}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it removes the backups, the saved restore error and the pause log"):
        ctx = setup_test()
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-restore-20261004T000000/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /root/imp-db-backups/pre-restore-20261004T000000/secrets/glm")
        machine.succeed("printf 'restore-impd-db: nothing was changed\\n' > /tmp/restore.err")
        machine.succeed("printf '[\"1\"]\\n' > /tmp/sleep.log")
        left_before = machine.succeed("find /root/imp-db-backups /tmp/restore.err /tmp/sleep.log | sort").split()

        ctx = setup_test()
        assert left_before == ["/root/imp-db-backups", "/root/imp-db-backups/pre-restore-20261004T000000", "/root/imp-db-backups/pre-restore-20261004T000000/secrets", "/root/imp-db-backups/pre-restore-20261004T000000/secrets/glm", "/tmp/restore.err", "/tmp/sleep.log"], f"the files were {left_before}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it uncovers imp-host's seccomp profile and removes the broken one"):
        ctx = setup_test()
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        machine.succeed("printf '{' > /tmp/broken-seccomp.json")
        machine.succeed(f"mount --bind /tmp/broken-seccomp.json {seccomp[0]}")
        covered_before = machine.succeed(f"cat {seccomp[0]}")

        ctx = setup_test()
        assert covered_before == "{", f"the seccomp profile read {covered_before!r}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it ends the holder of tank/imp mounted on a restore's directory in /run, unmounts it and removes the directory"):
        ctx = setup_test()
        run_dir = machine.succeed("mktemp -d /run/impd-restore.XXXXXX").strip()
        machine.succeed(f"mount -t zfs tank/imp {run_dir}")
        machine.succeed(f"cd {run_dir} && {{ sleep infinity < /dev/null > /dev/null 2>&1 & echo $! > /tmp/holder.pid; }}")
        holder = machine.succeed("cat /tmp/holder.pid").strip()
        busy_before = machine.execute(f"umount {run_dir}")[0]
        mounts_before = machine.succeed("findmnt -rn -S tank/imp -o TARGET").split()

        ctx = setup_test()
        assert re.fullmatch(r"/run/impd-restore\.\w{6}", run_dir), f"the restore's directory is {run_dir}"
        assert busy_before == 32, f"umount of the held mount exited {busy_before}"
        assert mounts_before == [run_dir], f"tank/imp was mounted on {mounts_before}"
        machine.fail(f"kill -0 {holder}")
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it starts docker again when it is stopped"):
        ctx = setup_test()
        machine.succeed("systemctl stop docker.socket docker.service")
        docker_before = machine.execute("systemctl is-active docker.socket docker.service")[1].split()

        ctx = setup_test()
        assert docker_before == ["inactive", "inactive"], f"docker was {docker_before}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it clears a unit that failed"):
        ctx = setup_test()
        machine.execute("systemd-run --unit=rehearsal-leftover --wait /run/current-system/sw/bin/false")
        failed_before = machine.execute("systemctl is-failed rehearsal-leftover")[1].strip()

        ctx = setup_test()
        assert failed_before == "failed", f"the leftover unit was {failed_before!r}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it starts imp-host and its proxy again when they are stopped"):
        ctx = setup_test()
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        units_before = machine.execute("systemctl is-active imp-host imp-docker-proxy")[1].split()

        ctx = setup_test()
        assert units_before == ["failed", "failed"], f"the imp units were {units_before}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it removes a container on another image, and that image"):
        ctx = setup_test()
        machine.succeed("docker pull ${image28.ref}")
        machine.succeed("docker run -d --name leftover ${image28.ref}")
        leftover_before = machine.succeed("docker inspect leftover --format '{{.Config.Image}}'").strip()

        ctx = setup_test()
        assert leftover_before == "${image28.ref}", f"the leftover container ran {leftover_before}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it returns to the booted system and its three generations after a switch to another"):
        ctx = setup_test()
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {ctx['old_path']}")
        machine.succeed(f"{ctx['old_path']}/bin/switch-to-configuration test")
        old_before = ctx["old_path"]
        current_before = machine.succeed("readlink -f /run/current-system").strip()
        profile_before = machine.succeed("readlink /nix/var/nix/profiles/system").strip()

        ctx = setup_test()
        assert current_before == old_before, f"the system was {current_before}"
        assert profile_before == "system-4-link", f"the system profile was {profile_before}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it returns to the booted system and its three generations when the current system points elsewhere and a generation is gone"):
        ctx = setup_test()
        machine.succeed(f"ln -sfn {ctx['old_path']} /run/current-system")
        machine.succeed("rm /nix/var/nix/profiles/system-1-link")
        old_before = ctx["old_path"]
        current_before = machine.succeed("readlink -f /run/current-system").strip()
        links_before = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()

        ctx = setup_test()
        assert current_before == old_before, f"the system was {current_before}"
        assert links_before == ["system-2-link", "system-3-link"], f"the generations were {links_before}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it empties tank/imp of files, snapshots and child datasets"):
        ctx = setup_test()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db && printf 'left\\n' > /mnt/imp/db/imp.sqlite")
        contents_before = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        machine.succeed("zfs snapshot tank/imp@leftover")
        machine.succeed("zfs create tank/imp/leftover")
        datasets_before = sorted(machine.succeed("zfs list -H -r -t all -o name tank/imp").split())

        ctx = setup_test()
        assert contents_before == "db\n", f"tank/imp held {contents_before!r}"
        assert datasets_before == ["tank/imp", "tank/imp/leftover", "tank/imp@leftover"], f"the datasets were {datasets_before}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it returns to the baseline after a restore that failed in its switch, leaving a new generation, failed units and its saved original"):
        ctx = setup_test()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' '.dbconfig no_ckpt_on_close on' 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image28.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        broken_before = ctx["broken_path"]

        status_before, out_before = machine.execute("SQLITE3=sqlite3 bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 2 2>/tmp/restore.err")
        err_before = machine.succeed("cat /tmp/restore.err").splitlines()
        saved_before = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").split()
        units_before = machine.succeed("systemctl show -p ActiveState --value imp-host imp-docker-proxy").split()
        switch_unit_before = machine.execute("systemctl is-failed fail-on-switch")[1].strip()
        current_before = machine.succeed("readlink -f /run/current-system").strip()
        links_before = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        generation_before = machine.succeed("readlink -f /nix/var/nix/profiles/system-4-link").strip()
        machine.succeed("mount -t zfs tank/imp /mnt/imp")
        contents_before = machine.succeed("cd /mnt/imp && find . | sort").split()
        machine.succeed("umount /mnt/imp")

        ctx = setup_test()
        assert status_before == 1, f"the restore exited {status_before}: {out_before}{err_before}"
        assert len(saved_before) == 1, f"the saved directories were {saved_before}"
        assert err_before[-1] == (
            f"restore-impd-db: the copy is in place (the original is in {saved_before[0]}); "
            "the switch or start did not finish; imp-host and imp-docker-proxy are stopped again"
        ), err_before
        assert units_before == ["failed", "failed"], f"the imp units were {units_before}"
        assert switch_unit_before == "failed", f"fail-on-switch was {switch_unit_before!r}"
        assert current_before == broken_before, f"the system was {current_before}"
        assert links_before == ["system-1-link", "system-2-link", "system-3-link", "system-4-link"], f"the generations were {links_before}"
        assert generation_before == broken_before, f"generation 4 was {generation_before}"
        assert contents_before == [".", "./db", "./db/imp.sqlite", "./secrets", "./secrets/glm"], f"tank/imp held {contents_before}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it returns to the baseline after a restore killed while it checks its staged copy, with tank/imp still mounted"):
        ctx = setup_test()
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed("install -d -m 0700 /mnt/imp/db")
        machine.succeed("install -d -m 0700 /mnt/imp/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /mnt/imp/secrets/glm && chmod 0600 /mnt/imp/secrets/glm")
        machine.succeed(
            "sqlite3 /mnt/imp/db/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t'),('0003_leases','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('original');\""
        )
        machine.succeed("umount /mnt/imp")
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-0.29-20261004T000000")
        machine.succeed(
            "sqlite3 /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite 'CREATE TABLE kysely_migration (name TEXT PRIMARY KEY, timestamp TEXT);' \"INSERT INTO kysely_migration VALUES ('0001_init','t'),('0002_tokens','t');\" 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('copy');\""
        )
        machine.succeed(
            "printf '%s\\n' 'path /var/lib/imp/db/imp.sqlite' \"sizeBytes $(stat -c %s /root/imp-db-backups/pre-0.29-20261004T000000/imp.sqlite)\" 'lastMigration 0002_tokens' 'impVersion 0.28.0' 'createdAt 2026-10-04T00:00:00.000Z' 'integrity ok' 'image ${image29.ref}' > /root/imp-db-backups/pre-0.29-20261004T000000/COPY-INFO"
        )
        machine.succeed("systemctl stop imp-host imp-docker-proxy")

        # the stand-in writes /tmp/holder.pid once the script is inside the check of its staged copy
        pid = machine.succeed("SQLITE3=${stubBlockingSqlite3} HOLDER_PID_FILE=/tmp/holder.pid bash ${../../scripts/restore-impd-db.sh} /root/imp-db-backups/pre-0.29-20261004T000000 3 > /tmp/restore.err 2>&1 < /dev/null & echo $!").strip()
        machine.wait_until_succeeds("test -s /tmp/holder.pid")
        blocked = machine.succeed("cat /tmp/holder.pid").strip()
        machine.succeed(f"kill -KILL {pid}")
        machine.wait_until_fails(f"kill -0 {pid}")
        blocked_before = machine.execute(f"kill -0 {blocked}")[0]
        out_before = machine.succeed("cat /tmp/restore.err").splitlines()
        saved_before = machine.succeed("ls -d /root/imp-db-backups/pre-restore-*").split()
        mounts_before = machine.succeed("findmnt -rn -S tank/imp -o TARGET").split()
        db_before = machine.succeed("ls -A /run/impd-restore.*/db").split()

        ctx = setup_test()
        assert blocked_before == 0, "the stand-in had stopped blocking before the reset"
        assert len(saved_before) == 1, f"the saved directories were {saved_before}"
        assert out_before == [
            "== check the copy",
            "== check the host",
            "== mount tank/imp",
            "== preserve the stopped database",
            f"saved: {saved_before[0]}",
            "== stage and check the copy",
        ], out_before
        assert len(mounts_before) == 1, f"tank/imp was mounted at {mounts_before}"
        assert re.fullmatch(r"/run/impd-restore\.\w{6}", mounts_before[0]), f"tank/imp was mounted at {mounts_before[0]!r}, not a /run/impd-restore.* directory"
        assert db_before == ["imp.sqlite", "imp.sqlite.restore"], f"the mounted database directory held {db_before}"
        machine.fail(f"kill -0 {blocked}")
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it makes tank/imp again after a reset that stopped once it had destroyed the dataset"):
        ctx = setup_test()
        # the reset's own steps up to its destroy of tank/imp
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("docker ps -aq | xargs -r docker rm -f")
        machine.succeed("docker images -q ghcr.io/zgeoff/imp-host | sort -u | xargs -r docker rmi -f")
        machine.succeed("zfs destroy -r tank/imp")
        dataset_before = machine.execute("zfs list -H -o name tank/imp 2>&1")
        units_before = machine.execute("systemctl is-active imp-host imp-docker-proxy")[1].split()
        images_before = machine.succeed("docker images -q ghcr.io/zgeoff/imp-host")

        ctx = setup_test()
        assert dataset_before == (1, "cannot open 'tank/imp': dataset does not exist\n"), f"tank/imp was {dataset_before}"
        assert units_before == ["failed", "failed"], f"the imp units were {units_before}"
        assert images_before == "", f"the images were {images_before}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it rebuilds the system profile after a reset that stopped once it had removed every generation"):
        ctx = setup_test()
        # the reset's own steps up to its removal of the system profile's links
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("docker ps -aq | xargs -r docker rm -f")
        machine.succeed("docker images -q ghcr.io/zgeoff/imp-host | sort -u | xargs -r docker rmi -f")
        machine.succeed("rm -f /nix/var/nix/profiles/system /nix/var/nix/profiles/system-*-link")
        profiles_before = [name for name in machine.succeed("ls -1 /nix/var/nix/profiles").split() if name.startswith("system")]
        units_before = machine.execute("systemctl is-active imp-host imp-docker-proxy")[1].split()
        images_before = machine.succeed("docker images -q ghcr.io/zgeoff/imp-host")

        ctx = setup_test()
        assert profiles_before == [], f"the system profile's links were {profiles_before}"
        assert units_before == ["failed", "failed"], f"the imp units were {units_before}"
        assert images_before == "", f"the images were {images_before}"
        booted = machine.succeed("readlink -f /run/booted-system").strip()
        specialisations = machine.succeed(f"readlink -f {booted}/specialisation/old {booted}/specialisation/broken").split()
        assert ctx == {"base_path": booted, "old_path": specialisations[0], "broken_path": specialisations[1]}, f"setup_test() returned {ctx}"
        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == booted, f"the system is {current}"
        profile = machine.succeed("readlink /nix/var/nix/profiles/system").strip()
        assert profile == "system-3-link", f"the system profile is {profile}"
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"
        generations = machine.succeed("cd /nix/var/nix/profiles && readlink -f system-1-link system-2-link system-3-link").split()
        assert generations == specialisations + [booted], f"the generations' systems are {generations}"
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units are failed: {failed}"
        active = machine.succeed("systemctl is-active docker.socket docker.service imp-host imp-docker-proxy").split()
        assert active == ["active", "active", "active", "active"], f"the units are {active}"
        containers = sorted(machine.succeed("docker ps -a --format '{{.Names}}'").split())
        assert containers == ["imp-docker-proxy", "imp-host"], f"the containers are {containers}"
        image = machine.succeed("docker inspect imp-host --format '{{.Config.Image}}'").strip()
        assert image == "${image29.ref}", f"imp-host runs {image}"
        images = machine.succeed("docker images --digests --format '{{.Repository}}@{{.Digest}}'").split()
        assert images == ["ghcr.io/zgeoff/imp-host@" + "${image29.ref}".split("@")[1]], f"the images are {images}"
        machine.fail("findmnt -rn -S tank/imp")
        targets = machine.succeed("findmnt -rn -o TARGET").split()
        backup_mounts = [target for target in targets if target.startswith("/root/imp-db-backups")]
        assert backup_mounts == [], f"mounted under the backups: {backup_mounts}"
        seccomp = re.findall(r"seccomp=(/nix/store/[^ ']+)", machine.succeed("cat /etc/systemd/system/imp-host.service"))
        assert len(seccomp) == 1, f"the unit names {seccomp}"
        machine.fail(f"mountpoint -q {seccomp[0]}")
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /tmp/sleep.log /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"

    '';
}
