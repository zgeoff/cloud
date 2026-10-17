# Move the host secrets onto tank/cloud

geoffcloud keeps imp-host's secret files in `/var/lib/imp-host/secrets`, the atc daemon's tokens in
`/var/lib/atc-daemon-secrets`, and impd's database copies in `/root/imp-db-backups`. All three sit
on `vda`, which Onidel snapshots, so every snapshot would hold the secrets in the clear. This
runbook moves their contents onto the encrypted datasets of [tank/cloud](./tank-cloud.md) and keeps
every path: the NixOS module bind-mounts a directory of a dataset at each old path, and no service
option changes.

| Path                          | Directory on tank/cloud                                   |
| ----------------------------- | --------------------------------------------------------- |
| `/var/lib/imp-host/secrets`   | `/var/lib/tank-cloud/host-secrets/imp-host`               |
| `/var/lib/atc-daemon-secrets` | `/var/lib/tank-cloud/host-secrets/atc-daemon`             |
| `/root/imp-db-backups`        | `/var/lib/tank-cloud/imp-db-backups` (the dataset's root) |

The sequence is a seed, a switch, a check and a removal. The seed copies the files across while the
old paths still serve the services. The switch mounts the binds, which shadow the old directories.
The removal deletes what the old directories still hold on `vda`. Until the removal, a rollback is a
revert and a switch. The host script `scripts/host/move-host-secrets.sh` does the seed, the
comparison and the removal. It never prints a file's content or a checksum.

The NixOS check `tank-cloud-host-secrets` rehearses every step in a VM: [Rehearse it](#rehearse-it)
gives the run.

## Before you start

Run each command on geoffcloud as root, over `ssh root@geoffcloud`, unless it says otherwise.

1. Check that the datasets are mounted and the key is loaded:

   ```bash
   findmnt -n -o SOURCE,FSTYPE --mountpoint /var/lib/tank-cloud/host-secrets
   findmnt -n -o SOURCE,FSTYPE --mountpoint /var/lib/tank-cloud/imp-db-backups
   zfs get -H -o value keystatus tank/cloud
   ```

   Expect `tank/cloud/host-secrets zfs`, `tank/cloud/imp-db-backups zfs`, then `available`.

2. Check that the target directories do not exist yet, because the seed refuses to copy into a
   directory that holds anything:

   ```bash
   ls -A /var/lib/tank-cloud/host-secrets/imp-host /var/lib/tank-cloud/host-secrets/atc-daemon
   ls -A /var/lib/tank-cloud/imp-db-backups
   ```

   Expect two `No such file or directory` errors from the first command and no output from the
   second.

3. Copy impd's database as well, if you want a copy from before the move. The copy lands on `vda`
   until the switch:

   ```bash
   bash scripts/copy-impd-db.sh pre-host-secrets-move
   ```

## Seed

1. From this machine, run the seed with the script on SSH's stdin:

   ```bash
   ssh root@geoffcloud bash -s -- seed < scripts/host/move-host-secrets.sh
   ```

   Expect one line per path: `seeded <path> -> <directory on tank/cloud>: <n> entries`. The script
   refuses, and copies nothing, when a dataset is not mounted, when a target directory is not empty,
   or when an old path is not a plain directory.

2. Compare the trees:

   ```bash
   ssh root@geoffcloud bash -s -- compare < scripts/host/move-host-secrets.sh
   ```

   Expect `match <path>: <n> entries, 0 only on tank/cloud` and a `root` line with the directory's
   mode and owner for each path. `MISMATCH <path>:` lists each differing entry with the field that
   differs. A `copy-impd-db.sh` copy taken between the seed and the compare is missing on
   tank/cloud: copy that entry across by hand with `cp -a`. A `differs` entry before the switch
   means the file changed on the old path after the seed, and that path is still the live one: copy
   it across by hand. After the switch it is the other way round
   ([Remove the old copies](#remove-the-old-copies)).

## Switch

**CAUTION:** The switch bounces the datasets. The binds change the order in which the pool's import
unit lists its mounts, so the switch restarts that unit, which unmounts and mounts the tank/cloud
datasets again. k3s, imp-host and the atc daemon stop with the datasets and start again once they
are back, which restarts k3s's pods and puts every awake imp to sleep.

1. The owner runs the switch from a clean checkout of `main`:

   ```bash
   bash scripts/switch-geoffcloud.sh
   ```

   The switch mounts the three binds, so `systemctl start tank-cloud.target` is not needed after it.

2. Check the services:

   ```bash
   systemctl is-active k3s imp-host atc-daemon imp-host-dns-token.path
   ```

   Expect `active` four times. When one is not,
   `systemctl start tank-cloud.target k3s imp-host atc-daemon imp-host-dns-token.path` mounts
   everything and starts them.

## Check

1. Check the mounts:

   ```bash
   for path in /var/lib/imp-host/secrets /var/lib/atc-daemon-secrets /root/imp-db-backups; do
     findmnt -n -o SOURCE,FSTYPE --mountpoint "$path"
   done
   ```

   Expect `tank/cloud/host-secrets[/imp-host] zfs`, `tank/cloud/host-secrets[/atc-daemon] zfs` and
   `tank/cloud/imp-db-backups zfs`.

2. Check that imp-host staged its secrets from the files on tank/cloud, and that a backup runs with
   the staged password:

   ```bash
   journalctl -u imp-host --since '-10 min' --no-pager | grep 'is missing or empty'
   docker exec imp-host impz backup run
   docker exec imp-host impz backup ls
   ```

   Expect no line from the `grep`, a backup run that exits 0, and the new backup last in the list.

3. From this machine, check the atc gateway against the daemon:

   ```bash
   bun scripts/check-atc-gateway-readiness.ts
   ```

   Expect every line `ok`.

4. Take one database copy, from this machine, and check where it lands:

   ```bash
   bash scripts/copy-impd-db.sh post-host-secrets-move
   ssh root@geoffcloud findmnt -n -o SOURCE -T /root/imp-db-backups
   ```

   Expect `integrity ok` in the copy's output, then `tank/cloud/imp-db-backups`.

5. Check that the files the two install scripts write sit on the new mounts.
   `scripts/install-imp-dns-token.sh` and `scripts/install-atc-gateway-credentials.ts` keep their
   paths, and each refuses to write while its path is not a mount point, as does
   `copy-impd-db-host`. A run of either is not needed for the check:

   ```bash
   for file in /var/lib/imp-host/secrets/dns-api-token /var/lib/imp-host/secrets/imp-host.env \
     /var/lib/atc-daemon-secrets/gateway-token /var/lib/atc-daemon-secrets/imp-token; do
     findmnt -n -o SOURCE -T "$file"
   done
   ```

   Expect `tank/cloud/host-secrets[/imp-host]` twice, then `tank/cloud/host-secrets[/atc-daemon]`
   twice.

## Remove the old copies

**CAUTION:** This deletes the old secret files from `vda`. Run it only after the checks above pass.
Past this point the copies on tank/cloud are the only copies, apart from 1Password, which stays the
source of every token. The script itself refuses to delete anything unless every old path is a mount
point and `compare` finds every old entry on tank/cloud with the same type, mode, owner, group, size
and content.

1. Run the removal:

   ```bash
   ssh root@geoffcloud bash -s -- remove-old < scripts/host/move-host-secrets.sh
   ```

   Expect the `compare` lines, with `match` for each path, then `removed <path>: <n> entries` for
   each. The script reads the old directories through a non-recursive bind mount of `/` that it
   removes when it exits. The directories stay, as the binds' mount points.

2. On `MISMATCH`, nothing was deleted. Read each named entry by its field:

   - `missing`: the entry exists only on the old path, such as a copy taken between the seed and the
     switch. Copy it across by hand, from the old directory as seen through
     `mount --bind / <directory>` into its directory on tank/cloud, with `cp -a`.
   - `differs` (`content`, `size`, `mode` or `owner`): the file changed after the seed, so the copy
     on tank/cloud is the live one and the copy on `vda` is stale. Never copy the old file over it,
     since that can reinstall a revoked token. Delete the stale old entry through the same bind
     (`rm`), and the removal no longer lists it.

   Run the removal again.

## Roll back

Before the removal, the old files are still on `vda`. Revert the commit that adds the binds and
switch again: the binds unmount, and the services read the old paths. A file written to a new mount
since the first switch, such as a rotated token, exists on tank/cloud only. Copy it from its
directory on tank/cloud to the old path before you restart the services.

After the removal, the old paths are empty on `vda`. Revert and switch as above, then copy each
directory on tank/cloud back with `cp -a <directory>/. <old path>/` before you restart the services.

## Rehearse it

The check needs KVM, and boots one VM:

```bash
bun run test:nixos tank-cloud-host-secrets
```

The check makes the datasets with the commands of [tank/cloud](./tank-cloud.md), seeds fake secrets
in geoffcloud's shapes under main's configuration, runs the seed and the comparison, switches to the
configuration with the binds, and checks the mounts, the services, the staged files and the daemon's
credential. It then takes a database copy, runs the removal, runs the two install scripts' host
halves against the new mounts, and reboots.

Result on 2026-10-17: the check passed under KVM, with all nine subtests, beside
`tank-cloud-unlock`, the four restore rehearsals, `impd-db-tools`, `geoffcloud-eval` and
`test-utils`.
