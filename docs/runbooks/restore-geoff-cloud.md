# Restore geoff.cloud

How to recover each part of geoff.cloud (#9). Each step says whether it was tested, and where.
Untested steps are marked **untested**. A restore on the live host is a consequential operation: get
approval for it first.

Pick the section for what you lost. Each section says what it restores, what it needs and how to
check the result.

| Lost                                | Section | Source                                                        |
| ----------------------------------- | ------- | ------------------------------------------------------------- |
| One imp, or every imp               | 1       | imp restic backups in R2 `geoff-cloud-backups/imp/geoffcloud` |
| impd's database after a bad upgrade | 2       | copies in `/root/imp-db-backups/`                             |
| A bad host change                   | 3       | the previous NixOS generation                                 |
| The root disk (`vda`)               | 4       | an Onidel snapshot, or a reinstall                            |
| The cluster's workloads             | 5       | Pulumi, rehearsed on a scratch cluster                        |
| The atc gateway's data              | 6       | `docs/runbooks/atc-gateway-backup-restore.md`                 |

## 1. Restore imps from restic

impd backs up every imp to R2 about every 6 hours. `imp backup ls` lists the backups, and
`last check` shows the last `restic check`.

1. List the backups:

   ```sh
   docker exec imp-host imp backup ls
   ```

2. Restore one imp, the newest backup at or before a time, or every imp:

   ```sh
   docker exec imp-host imp backup restore <name>
   docker exec imp-host imp backup restore <name> --at 2026-10-03T07:40:00Z
   docker exec imp-host imp backup restore <name> --as <name>-restored
   docker exec imp-host imp backup restore --all          # empty host
   docker exec imp-host imp backup restore --all --merge  # host with imps
   ```

   A restored imp is stopped. Start it with `imp start <name>`.

3. Check: `imp ls` shows the imp, and the impd log shows `backup: restored <name> from <snapshot>`.
   Loki has the same line under `{job="journal", unit="imp-host.service"}`.

Tested 2026-10-03 07:40 UTC with a test imp: backup `51815d88`, restored, then booted from the boot
template.

## 2. Roll impd's database back

Every imp upgrade takes a copy first with `bash scripts/copy-impd-db.sh <label>`. The copy is one
`imp.sqlite` file in `/root/imp-db-backups/<label>-<UTC time>/`, with `COPY-INFO` beside it: the imp
version, the image, the newest schema migration and the integrity check.

**CAUTION:** A restore discards every change impd made after the copy. It is one-way: impd runs
migrations forward only, and an older binary refuses a newer database. Restore a copy only with the
imp image named in its `COPY-INFO`. Disks and checkpoints made after the copy stay on the pool as
orphans; impd keeps them, but those imps leave `imp ls` until someone repairs them by hand.

Copies taken before the copy script by `tar` of a running impd may be torn. Prefer a copy with a
`COPY-INFO`.

1. Switch back to the NixOS generation whose imp image matches the copy (section 3).
2. Stop impd, so nothing writes during the restore:

   ```sh
   systemctl stop imp-host imp-docker-proxy
   ```

3. Mount the pool's dataset on the host, put the copy in place, and remove the WAL files (**untested
   on the host**; the file steps were rehearsed on an isolated WAL database):

   ```sh
   mkdir -p /mnt/imp-restore
   mount -t zfs tank/imp /mnt/imp-restore
   cp /root/imp-db-backups/<copy>/imp.sqlite /mnt/imp-restore/db/imp.sqlite
   rm -f /mnt/imp-restore/db/imp.sqlite-wal /mnt/imp-restore/db/imp.sqlite-shm
   umount /mnt/imp-restore
   systemctl start imp-host
   ```

4. Check: `docker exec imp-host imp info` shows the copy's version, `imp ls` matches the time of the
   copy, and `https://imps.geoff.cloud/health` returns 200.

Rehearsed 2026-10-04 on an isolated bun:sqlite WAL writer in Docker: five copies taken while it
wrote were all `ok`, and a stop, replace, drop -wal/-shm, start restore resumed from the copy.

## 3. Roll the host back one generation

```sh
ssh root@geoffcloud nixos-rebuild switch --rollback
```

`nix-env -p /nix/var/nix/profiles/system --list-generations` lists the generations. If imp's version
changes, restore the matching database copy too (section 2).

## 4. Recover the root disk

`vda` holds NixOS. `vdb` holds imp's ZFS pool and is never part of these steps.

- **From a snapshot:** `scripts/snapshot-geoffcloud.sh` takes one before a risky change. Restore it
  from the Onidel panel.
- **From nothing:** follow `docs/runbooks/reinstall-geoffcloud.md`. NixOS imports the pool from
  `vdb`, so the imps survive.

## 5. Rebuild the cluster

Recovery design (option C, accepted 2026-10-04): rebuild k3s, then let Pulumi recreate every object.
Nothing snapshots the k3s datastore.

**What is lost:** Loki's logs and Prometheus's metrics (both volumes start empty), and every object
that only lived in the cluster. **What survives:** imps (ZFS on `vdb`, outside k3s), Pulumi state
(R2), every secret (1Password), and the gateway's data (its own restic backup, section 6).

**Bootstrap dependencies:** the host with k3s running; the new kubeconfig in
`op://cloud/k3s-kubeconfig` (the server address over the tailnet; check it against the old item);
`.env` resolving through the `cloud` 1Password profile; Pulumi state in R2; the Helm repositories
and images reachable.

**CAUTION:** With `K3S_KUBECONFIG` empty, the program skips the cluster, and a preview plans to
delete every cluster resource from state (read from `infra/index.ts`; not rehearsed). Check the
preview before any apply.

1. Put the new kubeconfig in `op://cloud/k3s-kubeconfig`. With the old one, every run fails with
   `x509: certificate signed by unknown authority` and changes nothing.
2. Preview. Expect every cluster resource to show as a replace: the provider's kubeconfig changed.
3. Apply with the escape hatch, so Pulumi drops the objects it cannot reach on the old cluster:

   ```sh
   PULUMI_K8S_DELETE_UNREACHABLE=true bun run up -- --refresh
   ```

   A plain `bun run up` creates the new objects, then fails to delete the originals through the old
   provider. `bun run up -- --refresh` alone fails on the same unreachable reads.

4. Apply once more with `--refresh`. A service-account token Secret settles on the second pass.
5. Check: `bun run preview -- --refresh` shows 0 changes; every namespace, PVC and the dashboards
   exist; Grafana shows new data.
6. Restore the gateway's data (section 6), once the gateway exists.

Rehearsed 2026-10-03 on a throwaway k3s v1.35.8 in Docker, with the real `createClusterWorkloads`,
local Pulumi state and a fake tunnel token; no production access. Results: old kubeconfig → x509
failure, nothing changed; plain up → partial; `up --refresh` → fails; step 3 → 124 created; second
pass → 1 Secret settled; then 130 unchanged. Both PVCs came back empty (a marker file in Loki's
volume was gone). Not covered: the gateway (not released) and its restic restore; pod readiness
(node-exporter cannot run in k3s-in-Docker, so the rehearsal skipped readiness waits).

## 6. Restore the atc gateway

See `docs/runbooks/atc-gateway-backup-restore.md`.

## After any restore

- `https://imps.geoff.cloud/health` returns 200.
- Grafana's imp and cloudflared dashboards show current data.
- A refresh preview shows 0 changes (`bun run preview -- --refresh`).
