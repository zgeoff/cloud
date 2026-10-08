# Checks the restore rehearsal's reset, setup_test() in test-utils/build-restore-rehearsal.nix,
# on the rehearsal's own machine. Each subtest starts from the reset, leaves one kind of state
# that a rehearsal subtest can leave, runs the reset again, and checks the whole boot state the
# reset promises: the booted 0.29.0 system current; generations 1 (0.28.0), 2 (0.28.0, a switch
# that fails) and 3 (the booted one) in the system profile, and returned as the reset's three
# paths; no unit failed; docker and both imp units up; imp-host and its proxy the only
# containers, imp-host on its image, and that image the only one; an empty tank/imp with no
# snapshot or child, mounted nowhere; nothing mounted under the backups or over imp-host's
# seccomp profile; and no holder, backup, restore error or restore directory left. It needs KVM,
# and it reads scripts/ beside nixos/, so it builds only from the repo root: run
# `bun run test:nixos impd-restore-reset`.
{ nixpkgs, imp }:
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

        ctx = setup_test()
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
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
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

        ctx = setup_test()
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
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
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

        ctx = setup_test()
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
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it removes the backups and the saved restore error"):
        ctx = setup_test()
        machine.succeed("install -d -m 0700 /root/imp-db-backups/pre-restore-20261004T000000/secrets")
        machine.succeed("printf 'dummy-secret-value\\n' > /root/imp-db-backups/pre-restore-20261004T000000/secrets/glm")
        machine.succeed("printf 'restore-impd-db: nothing was changed\\n' > /tmp/restore.err")

        ctx = setup_test()
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
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
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

        ctx = setup_test()
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
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it removes the mount directories a restore left in /run"):
        ctx = setup_test()
        machine.succeed("mkdir /run/impd-restore.AAAAAA /run/impd-restore.BBBBBB")

        ctx = setup_test()
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
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
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

        ctx = setup_test()
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
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
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

        ctx = setup_test()
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
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
        assert left == "", f"the reset left {left}"
        datasets = machine.succeed("zfs list -H -r -t all -o name tank/imp").split()
        assert datasets == ["tank/imp"], f"the datasets are {datasets}"
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        contents = machine.succeed("ls -A /mnt/imp")
        machine.succeed("umount /mnt/imp")
        assert contents == "", f"tank/imp holds {contents}"


    with subtest("it starts imp-host fresh, removing other containers and images"):
        ctx = setup_test()
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("docker pull ${image28.ref}")
        machine.succeed("docker run -d --name leftover ${image28.ref}")

        ctx = setup_test()
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
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
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

        ctx = setup_test()
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
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
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

        ctx = setup_test()
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
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
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
        machine.succeed("umount /mnt/imp")
        machine.succeed("zfs snapshot tank/imp@leftover")
        machine.succeed("zfs create tank/imp/leftover")

        ctx = setup_test()
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
        left = machine.execute("ls -d /tmp/holder.pid /tmp/broken-seccomp.json /tmp/restore.err /root/imp-db-backups /run/impd-restore.* 2>/dev/null")[1]
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
