# The encryption of tank/imp (docs/runbooks/tank-imp-encryption.md) in a NixOS VM under imp's
# own module, as one journey whose subtests run in order. The VM boots the config geoffcloud gets
# after the switch, with imp-dataset-key on, and switches to the specialisation `plain`, today's
# config, before the migration. On a pool shaped like geoffcloud's, it makes the dataset tree
# impd makes, with the commands impd runs at the pinned imp (packages/daemon/src/storage/zfs):
# images with `@base`, disks cloned from them, checkpoints, a fork whose snapshot waits on
# `zfs destroy -d`, an image retired while a disk still needs its blocks, and impd's database,
# secrets and TLS files on the root. Then it runs the runbook: the first send while a writer
# changes the database, impd's own changes between the sends (a promote, a reclaim, new clones),
# the cutover, a rollback and a second cutover, and the end of the migration snapshots. On the
# encrypted root it runs impd's flows: clone, fork, promote, a move's send and receive, a backup's
# read-only clone, and the reclaim of a removed imp, with reclaim_step, a port of impd's
# planReclaimStep (zfs-reclaim.ts). Last, it reboots into the encrypted dataset with its key and
# then without it. The stand-in imp-host is busybox that only sleeps (build-stub-imp-host-image.nix),
# loaded from its archive in place of a pull, so the writer stands in for impd's database writes.
# The test utilities pass their own check (test-utils-check.nix) before the VM runs. It needs
# KVM: run `bun run test:nixos tank-imp-encrypt`.
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;
  # 64 hex characters, as keyformat=hex needs; a fixed value, never the host's key
  throwawayKey = lib.strings.replicate 8 "0f1e2d3c";
  image = import ./test-utils/build-stub-imp-host-image.nix { inherit pkgs; } "2.1.0";
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
in
pkgs.testers.runNixOSTest {
  name = "tank-imp-encrypt";
  nodes.machine =
    { config, ... }:
    {
      imports = [
        imp.nixosModules.imp
        ../modules/imp-dataset-key.nix
      ];
      networking.hostId = "5ca71846";
      # the VM reaches nothing, and dhcpcd crashing at times would fail a unit at boot
      networking.useDHCP = false;
      # imp-host's docker run passes --device /dev/kvm
      boot.kernelModules = [
        "kvm-amd"
        "kvm-intel"
      ];
      # as geoffcloud, where modules/tank-cloud.nix turns it off: the pool's import loads no key
      boot.zfs.requestEncryptionCredentials = false;
      virtualisation.emptyDiskImages = [ 4096 ];
      virtualisation.memorySize = 2048;
      environment.systemPackages = [ pkgs.sqlite ];

      services.imp = {
        enable = true;
        image = "ghcr.io/zgeoff/imp-host:2.1.0";
        imageArchive = image.archive;
        zfs.arcMaxMiB = 64;
        ramBudgetMiB = 512;
      };
      services.imp-dataset-key.enable = true;
      # today's config on geoffcloud, before the switch that turns the unlock on
      specialisation.plain.configuration.services.imp-dataset-key.enable = lib.mkForce false;

      # the pool, made once on the empty disk before its first import, with geoffcloud's
      # properties on tank; zpool create leaves a partition table, so a later boot only imports it
      systemd.services.rehearsal-pool = {
        requiredBy = [ "zfs-import-tank.service" ];
        before = [ "zfs-import-tank.service" ];
        requires = [ "dev-vdb.device" ];
        after = [ "dev-vdb.device" ];
        unitConfig.DefaultDependencies = false;
        path = [
          config.boot.zfs.package
          pkgs.util-linux
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
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
    key_url = "file:///var/lib/zfs-keys/tank.key"
    plain = "/run/booted-system/specialisation/plain/bin/switch-to-configuration test"
    # what the copy must keep of each dataset and snapshot; defer_destroy is compared on its own
    columns = "name,type,origin,recordsize,devices,setuid,refreservation,mountpoint,compression,atime,xattr"


    def relative(name, root):
        """name with root replaced by <root>, so trees under two roots compare"""
        if name == root or name.startswith(root + "/") or name.startswith(root + "@"):
            return "<root>" + name[len(root):]
        return name


    def tree(root):
        """every dataset and snapshot under root but the migration's, named relative to root"""
        rows = machine.succeed(f"zfs list -H -r -t filesystem,snapshot -s name -o {columns} {root}").splitlines()
        result = []
        for row in rows:
            fields = row.split("\t")
            if "@encrypt-" in fields[0]:
                continue
            result.append([relative(fields[0], root), fields[1], relative(fields[2], root)] + fields[3:])
        return result


    def deferred(root):
        """the snapshots under root that zfs destroy -d marked, relative to root"""
        rows = machine.succeed(f"zfs get -H -r -t snapshot -o name,value defer_destroy {root}").splitlines()
        return sorted(relative(r.split("\t")[0], root) for r in rows if r.split("\t")[1] == "on")


    def file_sums(root):
        """each filesystem's files and their sha256, mounted read-only one at a time"""
        result = {}
        for name in machine.succeed(f"zfs list -H -r -t filesystem -s name -o name {root}").split():
            machine.succeed(f"mkdir -p /mnt/sums && mount -t zfs -o ro {name} /mnt/sums")
            result[relative(name, root)] = machine.succeed("cd /mnt/sums && find . -type f -print0 | sort -z | xargs -0r sha256sum")
            machine.succeed("umount /mnt/sums")
        return result


    def reclaim_step(root):
        """impd's planReclaimStep (packages/daemon/src/storage/zfs/zfs-reclaim.ts at the pinned
        imp), over the list impd reads: the next promote or destroy that frees a retired disk or
        image, or None when none can go yet"""
        rows = machine.succeed(f"zfs list -Hp -r -t filesystem,snapshot -s createtxg -o name,type,origin,defer_destroy {root}").splitlines()
        entries = [dict(zip(["name", "type", "origin", "defer"], row.split("\t"))) for row in rows]
        filesystems = [e for e in entries if e["type"] == "filesystem"]
        clones = lambda snapshot: [f for f in filesystems if f["origin"] == snapshot]
        for retired in filesystems:
            if not retired["name"].startswith(f"{root}/retired/"):
                continue
            snapshots = [e for e in entries if e["type"] == "snapshot" and e["name"].startswith(retired["name"] + "@")]
            if any(s["defer"] != "on" for s in snapshots):
                continue
            unused = next((s for s in snapshots if not clones(s["name"])), None)
            if unused is not None:
                return ("destroy", unused["name"])
            if not snapshots:
                return ("destroy", retired["name"])
            clone = next((f for f in clones(snapshots[-1]["name"]) if not f["name"].startswith(f"{root}/staging/")), None)
            if clone is not None:
                return ("promote", clone["name"])
        return None


    def run_reclaim(root):
        """impd's reclaim pass: each step until none is left; returns the steps"""
        steps = []
        while (step := reclaim_step(root)) is not None:
            machine.succeed(f"zfs {step[0]} {step[1]}")
            steps.append((step[0], relative(step[1], root)))
        return steps


    def make_image(name):
        """an image as impd builds one: a dataset with rootfs.ext4, then @base"""
        machine.succeed(f"zfs create tank/imp/images/{name}")
        machine.succeed(f"mkdir -p /mnt/w && mount -t zfs tank/imp/images/{name} /mnt/w")
        machine.succeed("dd if=/dev/urandom of=/mnt/w/rootfs.ext4 bs=1M count=4 status=none")
        machine.succeed("umount /mnt/w")
        machine.succeed(f"zfs snapshot tank/imp/images/{name}@base")


    def make_disk(disk, origin):
        """an imp's disk: a clone of origin, then a guest's write into it"""
        machine.succeed(f"zfs clone {origin} tank/imp/disks/{disk}")
        machine.succeed(f"mkdir -p /mnt/w && mount -t zfs tank/imp/disks/{disk} /mnt/w")
        machine.succeed("dd if=/dev/urandom of=/mnt/w/rootfs.ext4 bs=64K count=4 seek=8 conv=notrunc status=none")
        machine.succeed("umount /mnt/w")


    def fork(disk, snapshot, clone):
        """impd's fork: a snapshot, its clone, and the snapshot marked to go with its last clone"""
        machine.succeed(f"zfs snapshot tank/imp/disks/{disk}@{snapshot}")
        machine.succeed(f"zfs clone tank/imp/disks/{disk}@{snapshot} tank/imp/disks/{clone}")
        machine.succeed(f"zfs destroy -d tank/imp/disks/{disk}@{snapshot}")


    def retire(name, retired):
        """impd's removeDataset: the disk or image leaves the namespace for retired/"""
        machine.succeed(f"zfs rename tank/imp/{name} tank/imp/retired/{retired}")


    def write_database(marker):
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed(f"sqlite3 /mnt/imp/db/imp.sqlite \"INSERT INTO marker VALUES ('{marker}');\"")
        machine.succeed("umount /mnt/imp")


    def send_increment(base, snapshot):
        """the cutover's send, with imp-host stopped and nothing of tank/imp mounted"""
        machine.succeed(f"zfs snapshot -r tank/imp@{snapshot}")
        machine.succeed(f"zfs send -R -I @{base} tank/imp@{snapshot} | zfs recv -u -F -x encryption tank/imp-new")


    def stop_imp_host():
        machine.succeed("systemctl stop imp-host")
        mounts = machine.succeed("findmnt -rn -o SOURCE | grep -E '^tank/imp(/|$)' || true")
        assert mounts == "", f"tank/imp is still mounted: {mounts}"


    machine.wait_for_unit("multi-user.target")


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it keeps imp-host stopped and makes no plain tank/imp when imp-dataset-key finds none"):
        machine.wait_until_succeeds("test \"$(systemctl show -p ActiveState --value imp-dataset-key)\" = failed")

        failed = machine.succeed("systemctl list-units --failed --plain --no-legend --full | cut -d' ' -f1").split()
        assert failed == ["imp-dataset-key.service"], f"the failed units are {failed}"
        key_log = machine.succeed("journalctl -b -u imp-dataset-key.service --no-pager")
        assert "imp-dataset-key: tank/imp is missing; imp's module would make a plain one" in key_log, key_log
        states = machine.succeed("systemctl show -p ActiveState --value imp-zfs-dataset imp-host").split()
        assert states == ["inactive", "inactive"], f"the units are {states}"
        machine.fail("zfs list tank/imp")


    # geoffcloud before the cutover: the plain config, tank/imp made by imp's module, and the key
    # file and tank/cloud of docs/runbooks/tank-cloud.md beside it
    machine.succeed("systemctl reset-failed")
    machine.succeed(plain)
    machine.succeed("systemctl start imp-host")
    machine.wait_for_unit("imp-host.service")
    machine.succeed("install -d -m 0700 /var/lib/zfs-keys")
    machine.succeed(f"printf '%s' {key} > /var/lib/zfs-keys/tank.key && chmod 0400 /var/lib/zfs-keys/tank.key")
    machine.succeed(f"zfs create -o encryption=aes-256-gcm -o keyformat=hex -o keylocation={key_url} -o mountpoint=legacy tank/cloud")

    # the tree impd makes, with geoffcloud's local properties
    machine.succeed("zfs set setuid=off tank/imp")
    for child in ["mem", "retired"]:
        machine.succeed(f"zfs create -o devices=off tank/imp/{child}")
    machine.succeed("zfs create -o devices=off -o refreservation=1G tank/imp/reserve")
    for child in ["disks", "images", "staging"]:
        machine.succeed(f"zfs create -o devices=off -o recordsize=16K tank/imp/{child}")
    machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
    machine.succeed("install -d -m 0700 /mnt/imp/db /mnt/imp/secrets /mnt/imp/tls /mnt/imp/broker")
    machine.succeed("sqlite3 /mnt/imp/db/imp.sqlite 'PRAGMA journal_mode=WAL;' 'CREATE TABLE marker (v TEXT);' \"INSERT INTO marker VALUES ('seeded');\"")
    for path in ["secrets/root-token", "secrets/glm", "tls/key.pem", "broker/ca.key"]:
        machine.succeed(f"head -c 64 /dev/urandom | base64 > /mnt/imp/{path} && chmod 0600 /mnt/imp/{path}")
    machine.succeed("umount /mnt/imp")
    make_image("img-a")
    make_image("img-b")
    make_disk("d1", "tank/imp/images/img-a@base")
    make_disk("d2", "tank/imp/images/img-a@base")
    make_disk("d4", "tank/imp/images/img-b@base")
    machine.succeed("zfs snapshot tank/imp/disks/d1@cp-1")
    fork("d1", "fork-1", "d3")
    # an image retired while d4 still needs its blocks: its @base waits on d4
    machine.succeed("zfs destroy -d tank/imp/images/img-b@base")
    retire("images/img-b", "r1")


    with subtest("it receives a filesystem new in an incremental replication stream as plain, unless recv excludes encryption"):
        machine.succeed("zfs create -o mountpoint=legacy tank/demo && zfs create tank/demo/a && zfs snapshot -r tank/demo@1")
        for copy in ["tank/demo-kept", "tank/demo-excluded"]:
            machine.succeed(f"zfs send -R tank/demo@1 | zfs recv -u -o encryption=on -o keyformat=hex -o keylocation={key_url} {copy}")
        machine.succeed("zfs create tank/demo/b && zfs snapshot -r tank/demo@2")

        machine.succeed("zfs send -R -I @1 tank/demo@2 | zfs recv -u -F tank/demo-kept")
        machine.succeed("zfs send -R -I @1 tank/demo@2 | zfs recv -u -F -x encryption tank/demo-excluded")

        kept = machine.succeed("zfs get -H -o value encryption tank/demo-kept/a tank/demo-kept/b").split()
        excluded = machine.succeed("zfs get -H -o value encryption tank/demo-excluded/a tank/demo-excluded/b").split()
        machine.succeed("zfs destroy -r tank/demo && zfs destroy -r tank/demo-kept && zfs destroy -r tank/demo-excluded")
        assert kept == ["aes-256-gcm", "off"], f"without -x encryption: {kept}"
        assert excluded == ["aes-256-gcm", "aes-256-gcm"], f"with -x encryption: {excluded}"


    with subtest("it sends tank/imp into an encrypted tank/imp-new while impd writes, and every dataset there is encrypted under tank/imp-new"):
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs tank/imp /mnt/imp")
        machine.succeed(
            "systemd-run --unit impd-writer --property=Type=exec -E PATH=/run/current-system/sw/bin bash -c "
            "'while :; do sqlite3 /mnt/imp/db/imp.sqlite \"INSERT INTO marker VALUES (datetime());\"; sleep 0.05; done'"
        )
        machine.wait_until_succeeds("test \"$(sqlite3 /mnt/imp/db/imp.sqlite 'SELECT count(*) FROM marker;')\" -gt 5")

        machine.succeed("zfs snapshot -r tank/imp@encrypt-1")
        machine.succeed(
            "zfs send -R tank/imp@encrypt-1 | zfs recv -u -o encryption=on -o keyformat=hex"
            f" -o keylocation={key_url} tank/imp-new"
        )

        machine.succeed("systemctl stop impd-writer")
        machine.succeed("umount /mnt/imp")
        state = machine.succeed("systemctl show -p ActiveState --value imp-host").strip()
        assert state == "active", f"imp-host is {state}"
        rows = machine.succeed("zfs get -H -r -t filesystem -o name,value encryptionroot,keystatus,encryption tank/imp-new").splitlines()
        values = {r.split("\t")[1] for r in rows}
        assert values == {"tank/imp-new", "available", "aes-256-gcm"}, f"tank/imp-new has {rows}"
        keylocation = machine.succeed("zfs get -H -o value keylocation tank/imp-new").strip()
        assert keylocation == key_url, f"the key location is {keylocation}"
        machine.succeed("zfs get -H -o value encryption tank/imp | grep -qx off")


    with subtest("it holds back impd's reclaim on the live tank/imp while the migration snapshots exist"):
        retire("disks/d3", "r2")

        held = reclaim_step("tank/imp")

        assert held is None, f"the reclaim would {held}"


    # impd's own changes between the sends: a new image and disk, a checkpoint taken and one
    # deleted, a new fork whose snapshot waits on its clone, and the database written again
    make_image("img-c")
    make_disk("d5", "tank/imp/images/img-c@base")
    fork("d5", "fork-9", "d9")
    machine.succeed("zfs snapshot tank/imp/disks/d2@cp-2")
    machine.succeed("zfs destroy tank/imp/disks/d1@cp-1")
    fork("d2", "fork-2", "d6")
    write_database("between-the-sends")


    # the snapshots waiting on a clone: two forks, and the image retired while d4 needs it
    marked = ["<root>/disks/d1@fork-1", "<root>/disks/d2@fork-2", "<root>/disks/d5@fork-9", "<root>/retired/r1@base"]


    with subtest("it cuts over: the increment lands with every clone, property and file, and the marks of zfs destroy -d do not travel"):
        stop_imp_host()

        send_increment("encrypt-1", "encrypt-2")

        plain_datasets = machine.succeed("zfs get -H -r -t filesystem -o name,value encryptionroot tank/imp-new | awk '$2 != \"tank/imp-new\"'")
        assert plain_datasets == "", f"datasets outside the encryption root: {plain_datasets}"
        assert tree("tank/imp-new") == tree("tank/imp"), f"the trees differ:\n{tree('tank/imp-new')}\n{tree('tank/imp')}"
        assert file_sums("tank/imp-new") == file_sums("tank/imp"), "the files differ"
        assert deferred("tank/imp") == marked, f"the source marks {deferred('tank/imp')}"
        assert deferred("tank/imp-new") == [], f"the copy marks {deferred('tank/imp-new')}"
        snapshots = machine.succeed("zfs list -H -t snapshot -o name -r tank/imp-new | grep -c @encrypt-2").strip()
        filesystems = machine.succeed("zfs list -H -t filesystem -o name -r tank/imp-new | wc -l").strip()
        assert snapshots == filesystems, f"{snapshots} @encrypt-2 snapshots for {filesystems} filesystems"


    with subtest("it renames the copies, marks again what zfs destroy -d marked, and starts imp-host on the encrypted tank/imp"):
        machine.succeed("zfs rename tank/imp tank/imp-old")
        machine.succeed("zfs rename tank/imp-new tank/imp")
        for name in deferred("tank/imp-old"):
            machine.succeed(f"zfs destroy -d {name.replace('<root>', 'tank/imp', 1)}")
        machine.succeed("systemctl start imp-host")

        machine.wait_for_unit("imp-host.service")
        assert deferred("tank/imp") == deferred("tank/imp-old"), f"the marks are {deferred('tank/imp')}"
        assert tree("tank/imp") == tree("tank/imp-old")
        rows = machine.succeed("zfs get -H -r -t filesystem -o value encryptionroot,keystatus tank/imp").split()
        assert set(rows) == {"tank/imp", "available"}, f"tank/imp has {set(rows)}"
        machine.succeed("zfs get -H -o value encryption tank/imp-old | grep -qx off")


    with subtest("it rolls back by renaming the copies back, and imp-host starts on the plain tank/imp"):
        stop_imp_host()
        # impd's writes on the encrypted copy while it ran, which the second cutover discards
        write_database("on-the-copy-before-the-rollback")

        machine.succeed("zfs rename tank/imp tank/imp-new")
        machine.succeed("zfs rename tank/imp-old tank/imp")
        machine.succeed("systemctl start imp-host")

        machine.wait_for_unit("imp-host.service")
        machine.succeed("zfs get -H -o value encryption tank/imp | grep -qx off")
        machine.succeed("zfs get -H -o value encryptionroot tank/imp-new | grep -qx tank/imp-new")
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs -o ro tank/imp /mnt/imp")
        last = machine.succeed("sqlite3 'file:/mnt/imp/db/imp.sqlite?immutable=1' 'SELECT v FROM marker ORDER BY rowid DESC LIMIT 1;'").strip()
        machine.succeed("umount /mnt/imp")
        assert last == "between-the-sends", f"the plain database ends with {last}"


    with subtest("it cuts over again after a rollback: recv -F drops the copy's own writes for the plain tank/imp's"):
        write_database("after-the-rollback")
        stop_imp_host()

        send_increment("encrypt-2", "encrypt-3")
        machine.succeed("zfs rename tank/imp tank/imp-old")
        machine.succeed("zfs rename tank/imp-new tank/imp")
        for name in deferred("tank/imp-old"):
            machine.succeed(f"zfs destroy -d {name.replace('<root>', 'tank/imp', 1)}")
        machine.succeed("systemctl start imp-host")

        machine.wait_for_unit("imp-host.service")
        assert tree("tank/imp") == tree("tank/imp-old")
        assert deferred("tank/imp") == deferred("tank/imp-old") == marked
        assert file_sums("tank/imp") == file_sums("tank/imp-old"), "the files differ"
        machine.succeed("mkdir -p /mnt/imp && mount -t zfs -o ro tank/imp /mnt/imp")
        markers = machine.succeed("sqlite3 'file:/mnt/imp/db/imp.sqlite?immutable=1' 'SELECT v FROM marker;'").splitlines()
        integrity = machine.succeed("sqlite3 'file:/mnt/imp/db/imp.sqlite?immutable=1' 'PRAGMA integrity_check;'").strip()
        machine.succeed("umount /mnt/imp")
        assert markers[-1] == "after-the-rollback" and "on-the-copy-before-the-rollback" not in markers, markers
        assert integrity == "ok", integrity


    with subtest("it frees every retired dataset through impd's reclaim once the migration snapshots go, and the marks made again take their snapshots"):
        # impd removes an imp right after the start: d6, the fork of d2@fork-2
        retire("disks/d6", "r4")
        held = reclaim_step("tank/imp")

        machine.succeed("zfs list -H -t snapshot -o name -r tank/imp | grep '@encrypt-' | xargs -r -n1 zfs destroy")

        assert held is None, f"the reclaim would {held}"
        left = machine.succeed("zfs list -H -t snapshot -o name -r tank/imp | grep -c '@encrypt-' || true").strip()
        assert left == "0", f"{left} migration snapshots are left"
        steps = run_reclaim("tank/imp")
        # the order of independent steps is not fixed; d4 is the clone of r1@base, so only
        # d4's promote must come before r1's destroy
        assert sorted(steps) == [
            ("destroy", "<root>/retired/r1"),
            ("destroy", "<root>/retired/r2"),
            ("destroy", "<root>/retired/r4"),
            ("promote", "<root>/disks/d4"),
        ], f"the reclaim ran {steps}"
        assert steps.index(("promote", "<root>/disks/d4")) < steps.index(("destroy", "<root>/retired/r1")), f"the reclaim ran {steps}"
        retired = machine.succeed("zfs list -H -r -o name tank/imp/retired").split()
        assert retired == ["tank/imp/retired"], f"retired holds {retired}"
        snapshots = machine.succeed("zfs list -H -t snapshot -o name -r tank/imp").split()
        # d9 still needs d5@fork-9
        assert deferred("tank/imp") == ["<root>/disks/d5@fork-9"], f"the marks left are {deferred('tank/imp')}"
        left = [s for s in snapshots if "@fork-" in s or "/disks/d4@" in s]
        assert left == ["tank/imp/disks/d5@fork-9"], f"the snapshots left are {left}"


    with subtest("it runs impd's clone, fork, promote, send, backup and reclaim on the encrypted root, and every new dataset is encrypted under tank/imp"):
        make_disk("d7", "tank/imp/images/img-c@base")
        machine.succeed("zfs snapshot tank/imp/disks/d7@cp-3")
        fork("d7", "fork-3", "d8")
        # a move: the disk's snapshot, then a clone stream against the image it was cloned from
        machine.succeed("zfs snapshot tank/imp/disks/d5@mv-1")
        machine.succeed("zfs send -i tank/imp/images/img-c@base tank/imp/disks/d5@mv-1 | zfs recv -u -o origin=tank/imp/images/img-c@base tank/imp/staging/mv-1")
        machine.succeed("zfs snapshot tank/imp/disks/d1@mv-2")
        machine.succeed("zfs send tank/imp/disks/d1@mv-2 | zfs recv -u tank/imp/staging/mv-2")
        # a backup: the disk's snapshot, cloned into staging and read through a read-only mount
        machine.succeed("zfs snapshot tank/imp/disks/d5@bk-1-d5")
        machine.succeed("zfs clone tank/imp/disks/d5@bk-1-d5 tank/imp/staging/bk-1-d5")
        machine.succeed("mkdir -p /mnt/bk && mount -t zfs -o ro tank/imp/staging/bk-1-d5 /mnt/bk")
        backup_sum = machine.succeed("sha256sum < /mnt/bk/rootfs.ext4")
        machine.succeed("umount /mnt/bk")
        machine.succeed("mkdir -p /mnt/w && mount -t zfs -o ro tank/imp/disks/d5 /mnt/w")
        disk_sum = machine.succeed("sha256sum < /mnt/w/rootfs.ext4")
        machine.succeed("umount /mnt/w")
        machine.succeed("mkdir -p /mnt/mv && mount -t zfs -o ro tank/imp/staging/mv-1 /mnt/mv")
        moved_sum = machine.succeed("sha256sum < /mnt/mv/rootfs.ext4")
        machine.succeed("umount /mnt/mv")
        for name in ["staging/bk-1-d5", "staging/mv-1", "staging/mv-2"]:
            machine.succeed(f"zfs destroy -r tank/imp/{name}")
        for name in ["d5@bk-1-d5", "d5@mv-1", "d1@mv-2"]:
            machine.succeed(f"zfs destroy tank/imp/disks/{name}")

        assert backup_sum == disk_sum == moved_sum, f"the backup {backup_sum}, the disk {disk_sum} and the move {moved_sum} differ"
        new = machine.succeed("zfs get -H -o value encryptionroot,keystatus tank/imp/disks/d7 tank/imp/disks/d8").split()
        assert new == ["tank/imp", "available"] * 2, f"the new disks are {new}"
        origin = machine.succeed("zfs get -H -o value origin tank/imp/disks/d8").strip()
        assert origin == "tank/imp/disks/d7@fork-3", f"d8's origin is {origin}"


    with subtest("it empties tank/imp/retired after a test imp is removed, through impd's reclaim"):
        # impd's removal of d7: its checkpoint marked, then the disk retired; the fork d8 still
        # needs d7@fork-3, so the reclaim promotes d8 before it destroys the retired disk
        machine.succeed("zfs destroy -d tank/imp/disks/d7@cp-3")
        retire("disks/d7", "r5")

        steps = run_reclaim("tank/imp")

        assert steps == [("promote", "<root>/disks/d8"), ("destroy", "<root>/retired/r5")], f"the reclaim ran {steps}"
        retired = machine.succeed("zfs list -H -r -o name tank/imp/retired").split()
        assert retired == ["tank/imp/retired"], f"retired holds {retired}"
        machine.fail("zfs list tank/imp/disks/d8@fork-3")


    with subtest("it loads tank/imp's key at boot with imp-dataset-key on, and starts imp-host on the same files"):
        sums = file_sums("tank/imp")
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("imp-host.service")

        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")
        assert failed == "", f"units failed at boot: {failed}"
        status = machine.succeed("zfs get -H -o value encryptionroot,keystatus tank/imp").split()
        assert status == ["tank/imp", "available"], f"tank/imp is {status}"
        machine.succeed("systemctl is-active imp-dataset-key")
        assert file_sums("tank/imp") == sums, "the files changed across the reboot"


    with subtest("without the key file, it boots to SSH with imp-host stopped, and makes no plain tank/imp"):
        machine.succeed("rm /var/lib/zfs-keys/tank.key")
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.wait_until_succeeds("test \"$(systemctl show -p ActiveState --value imp-dataset-key)\" = failed")

        failed = machine.succeed("systemctl list-units --failed --plain --no-legend --full | cut -d' ' -f1").split()
        assert failed == ["imp-dataset-key.service"], f"the failed units are {failed}"
        key_log = machine.succeed("journalctl -b -u imp-dataset-key.service --no-pager")
        assert "Failed to open key material file" in key_log, key_log
        states = machine.succeed("systemctl show -p ActiveState --value imp-zfs-dataset imp-host").split()
        assert states == ["inactive", "inactive"], f"the units are {states}"
        status = machine.succeed("zfs get -H -o value encryptionroot,keystatus tank/imp").split()
        assert status == ["tank/imp", "unavailable"], f"tank/imp is {status}"


    with subtest("it starts imp-host once the key is back"):
        machine.succeed(f"printf '%s' {key} > /var/lib/zfs-keys/tank.key && chmod 0400 /var/lib/zfs-keys/tank.key")

        machine.succeed("systemctl start imp-host")

        machine.wait_for_unit("imp-host.service")
        status = machine.succeed("zfs get -H -o value keystatus tank/imp").strip()
        assert status == "available", f"the key is {status}"
  '';
}
