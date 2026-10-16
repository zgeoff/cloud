# Encrypt tank/imp

`tank/imp` holds everything impd keeps on geoffcloud's pool: its database, root token, broker CA,
TLS key and secret values, and every imp's disk. This runbook moves it into an encrypted copy under
the same name, keyed by the file that unlocks [tank/cloud](./tank-cloud.md), so neither `vda` nor
`vdb` alone exposes it. A `zfs send` copies the dataset tree while impd runs, and a short cutover
with imp-host stopped sends the last changes and swaps the names. The plain copy stays as
`tank/imp-old` until its own removal, so a rollback is two renames.

The NixOS module `nixos/modules/imp-dataset-key.nix` loads `tank/imp`'s key at boot, before imp's
module checks the dataset. The NixOS check `tank-imp-encrypt` rehearses this runbook in a VM under
imp's module: [Rehearse it](#rehearse-it) gives the run and its result.

## What the copy changes

Four effects of the copy shape the steps, and the rehearsal shows each one.

- **New datasets.** An incremental replication stream carries a filesystem made since the last send,
  such as an image impd built, as a whole stream with its source's properties, and `zfs recv` keeps
  that filesystem plain under the encrypted parent. A disk cloned from it is plain too. The
  cutover's receive therefore passes `-x encryption`, which makes each new filesystem inherit the
  copy's encryption, as the zfs-receive man page describes.

- **Deferred destroys.** impd marks a snapshot with `zfs destroy -d` when a clone still needs it: a
  fork's snapshot, a retired image's `@base`. `zfs send` drops the mark, so on the copy such a
  snapshot would outlive its last clone, and impd's reclaim would never free a retired dataset that
  holds one. The cutover marks each one again on the copy.
- **Reclaim waits.** impd's reclaim skips a retired dataset that holds a snapshot without that mark.
  Every migration snapshot is such a snapshot, so from the first snapshot until
  [End the migration](#end-the-migration), on the plain dataset and then on the copy, a disk or
  image that impd retires stays in `tank/imp/retired`. The reclaim frees it at its next pass after
  the migration snapshots go.
- **Boot.** The pool's import loads no key, so `tank/imp` stays locked after a reboot until
  something loads its key. imp-dataset-key does that once a switch turns it on, and the switch comes
  after the cutover, because the unit refuses a plain `tank/imp`. Before that switch, a reboot needs
  [the key loaded by hand](#after-a-reboot-before-the-switch).

## Before you start

Run each command on geoffcloud as root, over `ssh root@geoffcloud`, unless it says otherwise. Every
migration snapshot is named `@encrypt-<n>`, which matches none of the snapshot names impd makes or
removes.

1. From this machine, copy impd's database, as [Workflows](./workflows.md#upgrade-imp) does before a
   switch:

   ```bash
   bash scripts/copy-impd-db.sh pre-tank-imp-encryption
   ```

   Expect the copy's directory and its `COPY-INFO` with `integrity ok`.

2. Check the key and its encryption root, without printing the key:

   ```bash
   stat -c '%U %a %s' /var/lib/zfs-keys/tank.key
   zfs get -H -o value keystatus tank/cloud
   ```

   Expect `root 400 64`, then `available`.

3. Check that the pool holds a second copy. The copy needs about the space `tank/imp` allocates:

   ```bash
   zpool list -H -o alloc,free tank
   zfs list -H -o name tank/imp-new tank/imp-old
   ```

   Expect the free space above the allocated space, then `dataset does not exist` for both names.

4. From this machine, record the imps:

   ```bash
   ssh root@geoffcloud docker exec imp-host impz ls --json > .scratch/imps-before.json
   ```

## Send the first copy

impd keeps running, and the copy is of the snapshot, so its writes after the snapshot wait for the
cutover. The send runs as a transient unit, so a dropped SSH session does not stop it.

1. Snapshot every dataset and start the send into `tank/imp-new`:

   ```bash
   zfs snapshot -r tank/imp@encrypt-1
   systemd-run --unit tank-imp-encrypt-1 -p Type=oneshot -p RemainAfterExit=yes \
     bash -o pipefail -c 'zfs send -R tank/imp@encrypt-1 | zfs recv -u -o encryption=on -o keyformat=hex -o keylocation=file:///var/lib/zfs-keys/tank.key tank/imp-new'
   ```

   `-u` leaves the copy unmounted, and `-o encryption=on` makes `tank/imp-new` an encryption root
   whose children inherit it.

2. Wait until the unit ends:

   ```bash
   systemctl show -p ActiveState,Result tank-imp-encrypt-1
   ```

   Expect `ActiveState=active` and `Result=success`. On `failed`, `journalctl -u tank-imp-encrypt-1`
   holds the error: destroy `tank/imp-new` with `zfs destroy -r tank/imp-new` and start again from
   step 1 with a new snapshot name.

3. Check the copy's encryption:

   ```bash
   zfs get -H -r -t filesystem -o value encryptionroot,keystatus tank/imp-new | sort | uniq -c
   ```

   Expect one count of `available` and one of `tank/imp-new`, each equal to the number of
   filesystems under `tank/imp-new`. `tank/imp` can hold more by now, because impd keeps working.

## Cut over

Every imp sleeps during the cutover, for about 5 to 15 minutes. Put the imps to sleep first, so each
one keeps its memory.

1. From this machine, record the imps again, as in [Before you start](#before-you-start), into
   `.scratch/imps-cutover.json`.
2. Stop imp-host and its Docker proxy, and check that no imp-host container is left. impd mounts
   `tank/imp` inside the container, so the host's own mount table never lists it:

   ```bash
   systemctl stop imp-host imp-docker-proxy
   docker ps -aq --filter name=imp-host
   findmnt -rn -o SOURCE | grep -E '^tank/imp(/|$)'
   ```

   Expect no line from either command.

3. Send the changes since the first copy. `-I` sends every snapshot taken in between, such as a new
   checkpoint, `-F` makes the copy match by destroying what impd destroyed in the meantime, and
   `-x encryption` encrypts each filesystem made in the meantime.

   ```bash
   zfs snapshot -r tank/imp@encrypt-2
   systemd-run --unit tank-imp-encrypt-2 -p Type=oneshot -p RemainAfterExit=yes \
     bash -o pipefail -c 'zfs send -R -I @encrypt-1 tank/imp@encrypt-2 | zfs recv -u -F -x encryption tank/imp-new'
   systemctl show -p ActiveState,Result tank-imp-encrypt-2
   ```

   `systemd-run` returns once the send ends, and the unit finishes it if SSH drops first. Expect
   `ActiveState=active` and `Result=success`.

4. Check the copy's encryption again, as after the first send. Expect `tank/imp-new` as the
   encryption root of every filesystem. A plain one means the receive missed `-x encryption`:
   destroy `tank/imp-new`, start imp-host, and start again from
   [Send the first copy](#send-the-first-copy).
5. Compare the two trees, with their clone origins, and the snapshots marked for deferred destroy:

   ```bash
   for root in tank/imp tank/imp-new; do
     zfs list -H -r -t filesystem,snapshot -s name -o name,origin "$root" | sed -E "s#$root([/@[:space:]]|\$)#<root>\1#g" > "/root/tree-${root#tank/}"
   done
   diff /root/tree-imp /root/tree-imp-new && echo same
   zfs get -H -r -t snapshot -o name,value defer_destroy tank/imp | awk '$2 == "on" { print $1 }' > /root/deferred
   ```

   Expect `same`. `/root/deferred` lists the marks for step 7.

6. Swap the names:

   ```bash
   zfs rename tank/imp tank/imp-old
   zfs rename tank/imp-new tank/imp
   ```

7. Mark each deferred snapshot again on the copy. The mark destroys nothing while a clone needs the
   snapshot; ZFS destroys it with its last clone, as it would have on the plain dataset:

   ```bash
   xargs -r -n1 zfs destroy -d < /root/deferred
   ```

   The names in `/root/deferred` read `tank/imp/…`, which the renames made the copy's names.

8. Start imp-host, then check impd from this machine:

   ```bash
   systemctl start imp-docker-proxy imp-host
   ```

   ```bash
   ssh root@geoffcloud docker exec imp-host impz info
   ```

   Expect the version line and the imp count from before.

## Check the cutover

Run each check. If one fails, [roll back](#roll-back).

1. Every dataset is encrypted under `tank/imp`, with its key loaded:

   ```bash
   zfs get -H -r -t filesystem -o value encryptionroot,keystatus tank/imp | sort | uniq -c
   ```

   Expect `tank/imp` and `available`, each counted once per filesystem.

2. From this machine, the imps match the list taken at the cutover:

   ```bash
   ssh root@geoffcloud docker exec imp-host impz ls --json > .scratch/imps-after.json
   diff <(jq -S '[.[] | {name, state}]' .scratch/imps-cutover.json) <(jq -S '[.[] | {name, state}]' .scratch/imps-after.json)
   ```

   Expect no output.

3. Wake one imp with `impz wake <imp>`, and run a backup with `impz backup run`, both in the
   imp-host container. Expect the imp awake in `impz ls`, and the backup run to end without an
   error.

## End the migration

1. Destroy the migration snapshots on `tank/imp`. Leave `tank/imp-old` and its snapshots as they
   are:

   ```bash
   zfs list -H -t snapshot -o name -r tank/imp | grep '@encrypt-' | xargs -r -n1 zfs destroy
   zfs list -H -t snapshot -o name -r tank/imp | grep -c '@encrypt-'
   ```

   Expect `0`.

2. Create a test imp, remove it with `impz rm`, and list the retired datasets:

   ```bash
   zfs list -H -r -o name tank/imp/retired
   ```

   Expect `tank/imp/retired` alone once the reclaim has run, a few seconds after the removal.

3. Switch geoffcloud to a commit that turns imp-dataset-key on, as
   [Workflows](./workflows.md#switch-the-host) describes. Then check
   `systemctl is-active imp-dataset-key imp-host`: expect `active` twice.

## Roll back

A rollback puts the plain dataset back under its name, with every write impd made to the copy lost.
Run it while `tank/imp-old` exists and before the switch that turns imp-dataset-key on, because that
unit refuses a plain `tank/imp`.

```bash
systemctl stop imp-host imp-docker-proxy
zfs rename tank/imp tank/imp-new
zfs rename tank/imp-old tank/imp
systemctl start imp-docker-proxy imp-host
```

To cut over again later, start at [Cut over](#cut-over) with the next snapshot name, sending
`-I @encrypt-2 tank/imp@encrypt-3` with the same `-F -x encryption`. `-F` drops what impd wrote to
the copy while it ran.

## After a reboot before the switch

imp-host fails to start, because impd cannot mount a locked dataset. Load the key and start it:

```bash
zfs load-key tank/imp
systemctl start imp-host
```

After the switch, imp-dataset-key loads the key at boot. When it fails, the unit's journal holds the
reason, and imp-host stays stopped: restore the key file as
[tank/cloud](./tank-cloud.md#if-the-key-fails-to-load-at-boot) describes, then run
`systemctl start imp-host`.

## Rehearse it

The check needs KVM, and boots one VM:

```bash
bun run test:nixos tank-imp-encrypt
```

On a pool with geoffcloud's properties, it builds the dataset tree impd builds, with the commands
impd runs: images with `@base`, disks cloned from them, checkpoints, a fork marked for deferred
destroy, and an image retired while a disk needs it. It runs the first send while a writer changes
the database, impd's own changes between the sends, the cutover, a rollback and a second cutover,
and the end of the migration snapshots. On the encrypted copy it runs impd's clone, fork, promote, a
move's send and receive, a backup's read-only clone, and the reclaim of a removed imp, with a port
of impd's reclaim planner. It reboots with imp-dataset-key on, then without the key file.

Run of 2026-10-17, with nixpkgs and imp as `nixos/flake.lock` pins them: every subtest passed, and
the test script took 151 s. Three of its results set the steps of this runbook:

- Without `-x encryption`, an image built between the sends, and the disk cloned from it, landed
  plain under `tank/imp-new`. With it, both landed under the copy's encryption root.
- The source held three snapshots marked by `zfs destroy -d`, and the copy held none until the
  cutover marked them again. Each one then went with its last clone.
- impd's reclaim planner skipped each retired dataset until the migration snapshots went, then freed
  every one of them.
