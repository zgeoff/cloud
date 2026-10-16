# Restore drill

A restore drill proves that geoff.cloud's backups restore on a machine other than geoffcloud, and
measures how long each restore takes. It runs on one scratch Onidel VM, which only reads the backups
and is destroyed at the end, pass or fail. [Restore geoff.cloud](./restore-geoff-cloud.md) gives the
restores on the live host; this runbook rehearses an impd database copy and hq from its off-PC
backup away from it. A root-disk snapshot restore is described but **untested**: no drill has run
one.

**CAUTION:** Every step reads geoffcloud, its snapshots and the backup repositories, and never
writes to them. Use `--no-lock` on every restic command, because a lock is a write to the
repository.

## Size the scratch VM

Onidel's on-demand (hourly) tier caps a VM at 2 vCPU, 4 GB of RAM and a 40 GB disk, as the account
owner confirmed with Onidel. A create with a 240 GB disk returned `http 403` with
`{"err":"ONDEMAND_VM_COST_LIMIT"}`, and the refusal stayed after prepaid credit was added; a create
at 2 vCPU, 4 GB and 40 GB succeeded. The database copy and hq fit in 40 GB. A snapshot of
geoffcloud's `vda` needs a disk at least as large as the snapshot, and the root disk is 240 GB, so a
snapshot restore needs a monthly VM (see
[Restore a root-disk snapshot](#restore-a-root-disk-snapshot)).

1. Create the VM with Debian 12, hourly, in Sydney: `POST /vm` with `cpu` 2, `ram` 4096, `disk` 40
   and `payment_cycle` `hourly`. Expect `http 201` with no body; `GET /vm` lists the VM as
   `building`, then `active` after about 80 s.
2. Read the root password from `GET /vm/<vm_id>` into a root-only file, never to the terminal, and
   log in with it once to add a scratch SSH key.
3. Install `sqlite3`, and restic 0.18.1 from its release page, checked against `SHA256SUMS`. 0.18.1
   is the version [nixie's backup](./nixie-backup.md) pins.

## Restore an impd database copy

1. Choose the newest copy with a `COPY-INFO` in `/root/imp-db-backups/` on geoffcloud, and stream it
   to the scratch VM:

   ```bash
   ssh root@geoffcloud tar -C /root/imp-db-backups -cf - <copy> \
     | ssh root@<scratch_vm> 'mkdir -p /root/restore/impd && tar -C /root/restore/impd -xf -'
   ```

2. On the scratch VM, open it read-only, and compare it with its `COPY-INFO`:

   ```bash
   cd /root/restore/impd/<copy>
   sqlite3 -readonly imp.sqlite 'PRAGMA integrity_check;'
   sqlite3 -readonly imp.sqlite 'SELECT name FROM kysely_migration ORDER BY name DESC LIMIT 1;'
   ```

   Expect `ok`, and the migration in the `lastMigration` line of `COPY-INFO`.

3. Compare the copy's checksum with the host's file. Expect the same hash from both:

   ```bash
   ssh root@geoffcloud sha256sum /root/imp-db-backups/<copy>/imp.sqlite
   ssh root@<scratch_vm> sha256sum /root/restore/impd/<copy>/imp.sqlite
   ```

## Restore hq from its off-PC backup

hq backs up to its own restic repository at the `hq/` prefix of nixie's R2 bucket. The vault item
`hq-restic` holds its password, and `r2-nixie-backup` holds the R2 key that reads it; the
`r2-backups` key gets `Access Denied` there. Send the four values to the VM on SSH's stdin, never on
a command line: the workstation writes them as `export` lines ahead of the restore steps, and the VM
runs the whole stream with `bash -s`. `printf %q` quotes each value, and nothing prints it.

```bash
{
  printf 'export RESTIC_PASSWORD=%q\n' "$(op read op://cloud/hq-restic/password)"
  printf 'export AWS_ACCESS_KEY_ID=%q\n' "$(op read op://cloud/r2-nixie-backup/access-key-id)"
  printf 'export AWS_SECRET_ACCESS_KEY=%q\n' "$(op read op://cloud/r2-nixie-backup/secret-access-key)"
  printf 'export RESTIC_REPOSITORY=%q\n' "s3:$(op read op://cloud/r2-nixie-backup/endpoint)/geoff-cloud-nixie/hq"
  cat <<'STEPS'
export AWS_DEFAULT_REGION=auto
restic --no-lock snapshots --latest 1
restic --no-lock restore latest --target /root/restore/hq
sqlite3 -readonly "$(find /root/restore/hq -name hq.db | head -1)" 'PRAGMA integrity_check;'
STEPS
} | ssh root@<scratch_vm> 'bash -s'
```

Expect restic's `Summary: Restored <n> files/dirs`, and `ok` from the integrity check.

## Restore a root-disk snapshot

`POST /vm/<vm_id>/restore-snapshot` restores a snapshot onto a VM. The API has no volume endpoint,
and Onidel's block storage page offers monthly terms only, so neither an hourly VM nor a volume
holds a 240 GB snapshot. `POST /snapshots/<snapshot_id>` returns a download URL for a snapshot; its
file format and size are not documented.

**CAUTION:** A VM restored from geoffcloud's snapshot boots as geoffcloud: the same static address,
Tailscale identity, cloudflared tunnel and k3s backup jobs. In Melbourne it could share the live
host's network and claim its address, so restore it in another location. **Untested:** whether the
clone's outbound traffic stays contained there. Its static address has no route back to it, so a
reply should go to the live host, but no drill has checked that. Contain a clone before its services
reach the network: disable Tailscale, cloudflared and k3s on the restored disk from a rescue boot
first.

## Destroy the VM

1. Delete it: `DELETE /vm/<vm_id>`. Expect `http 204`.
2. Poll `GET /vm/<vm_id>` until it returns `http 404`, then list `GET /vm` and check that the VM is
   gone.

## Results

Drill of 2026-10-16, on a Debian 12.12 VM in Sydney, 2 vCPU, 4 GB, 40 GB:

| Restore            | Source                                      | Time    | Result                                                                                         |
| ------------------ | ------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------- |
| impd database copy | `imp-1.6.0-pre-2.0.3-20261015T214524`, 2 MB | 1.24 s  | checksum matches, `integrity_check` ok, 23 tables, newest migration `032_add_imp_oops_boot_id` |
| hq                 | restic snapshot `f337c714`                  | 15.76 s | 3804 files and directories, 1.920 GiB, `hq.db` `integrity_check` ok, 28 tables                 |
| root-disk snapshot | `pre-tank-cloud`, 240 GB                    | none    | not run                                                                                        |

The root-disk snapshot restore did not run. An on-demand VM caps at 40 GB and the snapshot is 240
GB, and the owner chose neither a monthly VM nor the snapshot download. The encryption of `tank/imp`
and the moves onto `tank/cloud` and an encrypted zvol each keep their old copy until their checks
pass, so none of them rolls back from a root-disk snapshot.

The VM lived from 11:14:22Z to 11:17:38Z, under one hourly block at A$0.0213. After the delete,
`GET /vm/<vm_id>` returned `http 404` and `GET /vm` listed geoffcloud only.
