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
| `vda`, `vdb` or both disks          | 4       | a snapshot or a reinstall, then the backups                   |
| The cluster's workloads             | 5       | Pulumi, rehearsed on a scratch cluster                        |
| The atc gateway's data              | 6       | `docs/runbooks/atc-gateway-backup-restore.md`                 |

## 1. Restore imps from restic

impd backs up every imp to R2 about every 6 hours. `impz backup ls` lists the backups, and
`last check` shows the last `restic check`.

1. List the backups:

   ```sh
   docker exec imp-host impz backup ls
   ```

2. Restore one imp, the newest backup at or before a time, or every imp:

   ```sh
   docker exec imp-host impz backup restore <name>
   docker exec imp-host impz backup restore <name> --at 2026-10-03T07:40:00Z
   docker exec imp-host impz backup restore <name> --as <name>-restored
   docker exec imp-host impz backup restore --all          # empty host
   docker exec imp-host impz backup restore --all --merge  # host with imps
   ```

   A restored imp is stopped. Start it with `impz start <name>`.

3. Check: `impz ls` shows the imp, and the impd log shows `backup: restored <name> from <snapshot>`.
   Loki has the same line under `{job="journal", unit="imp-host.service"}`.

Tested 2026-10-03 07:40 UTC with a test imp: backup `51815d88`, restored, then booted from the boot
template.

## 2. Roll impd's database back

Every imp upgrade takes a copy first with `bash scripts/copy-impd-db.sh <label>`. The copy is one
`imp.sqlite` file in `/root/imp-db-backups/<label>-<UTC time>/`, with `COPY-INFO` beside it: `path`,
`sizeBytes`, `lastMigration`, `impVersion`, `createdAt` and `integrity`, the names
`impz db copy --json` returns (imp #171), plus `image`, which impd cannot know. Copies from before
those names say `imp` and `migration`; the restore script reads both. `restore-impd-db` puts a copy
back. The host's NixOS config puts it and the copy's host side on the host's PATH, with the sqlite3
of the flake's pinned nixpkgs, so a fix to either reaches the host only with a host switch.

**CAUTION:** A restore discards every change impd made after the copy. It is one-way: impd runs
migrations forward only, and an older binary refuses a newer database. Disks and checkpoints made
after the copy stay on the pool as orphans: impd may log them at start, keeps them, and
`impz gc --dry-run` lists them. That log is expected, not a failure. Those imps leave `impz ls`
until someone repairs them by hand. Tokens follow the database too: a token minted after the copy
stops working, and a token revoked after it works again. The root `token` file, `broker/` and `tls/`
are not in the database and stay valid. Re-mint any token minted after the copy, such as
`atc-cloud`. Copies taken by `tar` of a running impd, before the copy script, have no `COPY-INFO`
and may be torn; the restore script refuses them.

**CAUTION:** Never switch generations while impd's database and image disagree. Do not rely on a
switch to leave imp-host stopped: in the VM rehearsal a clean switch left a stopped imp-host
stopped, but a failed switch started a container. A runtime mask cannot hold it down on NixOS
either: the units in `/etc/systemd/system` outrank `/run`. So restore the database first, with impd
stopped, and switch after.

1. Choose the copy, and read its `COPY-INFO`. Find the NixOS generation that runs its image:

   ```sh
   grep -o 'ghcr.io/zgeoff/imp-host:[^ ;]*' /nix/var/nix/profiles/system-*-link/etc/systemd/system/imp-host.service
   ```

2. Stop impd:

   ```sh
   systemctl stop imp-host imp-docker-proxy
   ```

3. Run the restore on the host with the copy and that generation:

   ```sh
   ssh root@geoffcloud restore-impd-db /root/imp-db-backups/<copy> <generation>
   ```

   The copy's newest migration must be at or below the newest migration of the image that starts; a
   newer copy fails at start. Matching the image in `COPY-INFO` to the generation's image meets
   that.

   It fails closed. Before it changes anything it checks the copy (integrity, `COPY-INFO`, its
   migration), reads both units' state and requires `inactive` or `failed`, checks that no
   `imp-host` or `imp-docker-proxy` container runs, that the generation exists and runs the copy's
   image, and that the dataset is not mounted. Then it mounts `tank/imp` and saves the stopped
   database, its WAL files and impd's secret values, root-only, to
   `/root/imp-db-backups/pre-restore-<UTC time>/`, flushes that filesystem and compares every saved
   file with its original. Only then does it stage the copy beside the database, check it, and
   publish it with one rename. After a clean unmount it activates the generation (when it is not the
   current one), starts imp-host, waits up to 60 s for its container, and checks that it runs the
   copy's image. On an error it says how far it got; if the switch or the start had begun, it stops
   both units again.

   **CAUTION:** A database-only restore is an incomplete recovery. At start, impd deletes every
   secret value that no database row names, so a copy older than a secret loses that secret's value,
   and the grants that used it break. The script saves the stopped secret values first, in
   `secrets/` of the saved directory (root-only, never printed); re-add any secret the copy lacks
   with `impz secret add`, reading the value from that file or from its source. Until imp ships
   `impz db copy` and its documented restore (imp #171), this runbook is the recovery contract.

4. Check the restored impd. `impz` is imp's CLI from its rename on, and an image from before the
   rename has only `imp`, so each command runs whichever CLI the container has:

   ```sh
   docker exec imp-host sh -c 'if command -v impz > /dev/null; then impz info; else imp info; fi'
   docker exec imp-host sh -c 'if command -v impz > /dev/null; then impz ls; else imp ls; fi'
   ```

   Expect `info` to show the copy's `impVersion` from `COPY-INFO`, `ls` to match the time of the
   copy, and `https://imps.geoff.cloud/health` to return 200.

**Reboot window.** If the host reboots during step 3, imp-host starts on the current generation,
against whatever the dataset holds then. Do not assume nothing changed: check the script's output
for how far it got, and the saved directory. Before the saved files are flushed, the original
database is untouched. After the WAL files are removed but before the rename, `db/imp.sqlite` is the
original without its last WAL writes, beside a staged `imp.sqlite.restore`; the full original is in
the saved directory. After the rename, the copy is in place, and a newer image migrates it forward.
In every case, stop impd and rerun from step 1; to return to the original, restore the saved
directory's files the same way.

**Evidence.** Synthetic only, 2026-10-04: an isolated bun:sqlite WAL writer in Docker gave five
consistent copies while it wrote. The restore script ran in a privileged throwaway container with a
fake pool, fake generations and stubbed `systemctl`, `docker`, `mount` and `nix-env`: a restore on
the current generation and a rollback to an older one each restored the copy, saved the secrets,
switched when needed, started and ran the copy's image; a copy with the old `COPY-INFO` names and
one with the new names each restored. An active or activating unit, an unreadable unit state, a
running container, an image mismatch, a missing generation, a missing `COPY-INFO`, a corrupt copy, a
migration mismatch, a failed copy into the pool and a failed unmount each stopped with nothing
started or switched. A failed switch and a wrong image after the start each stopped both units
again. A container that never appeared within the wait also stopped both units again.

Rehearsed in a KVM NixOS VM, 2026-10-04, and again on 2026-10-07 under imp's own NixOS module
(`nixos/checks/impd-restore.nix`), with the images pinned by tag and digest as geoffcloud pins them
and pulled from a registry inside the VM: the real ZFS mount of the module's legacy `tank/imp`
holding a WAL database and secrets, and a real generation switch. A restore to an older generation
saved the database, its WAL files and the secrets root-only, put the copy in place, unmounted,
switched, and started imp-host on the copy's digest-pinned image, which `docker inspect` reported as
the same `tag@sha256:…` string the unit names. A restore to the running generation skipped the
switch; a database without WAL files and a dataset without secrets restored too. It refused, with
nothing changed, without arguments, while either unit or an imp-host container ran, while `tank/imp`
was mounted, for a dataset without `imp.sqlite`, for a copy without `imp.sqlite` or `COPY-INFO`,
failing `integrity_check`, lacking the image or the migration, or with a different migration, and
for a generation that was not a number, did not exist or ran another image. The stand-ins: busybox
containers that only sleep, a proxy that only opens its socket, the local registry, and generations
that are the VM's own specialisations. A second check on the same machine,
`nixos/checks/impd-restore-saved-failures.nix`, reaches through real state the failures that come
after the original is saved: a real switch failure, and a start that never produced a container
within the wait, each stopped both units again; saved secrets or a saved database file that differed
from the original stopped the restore before the copy went in place. A third,
`nixos/checks/impd-restore-boundaries.nix`, reaches the errors no real state can: a unit whose state
cannot be read, and a staged or published file that differs from the copy, through a stand-in
`systemctl` or `cmp` that fails only that one call. Each stopped as before, with nothing started or
switched. Every failure after the save left the original in its saved directory. A fourth,
`nixos/checks/impd-restore-reset.nix`, checks that the machine's reset between subtests clears what
each subtest can leave. Run them on a machine with Docker and KVM:

```sh
bun run test:nixos impd-restore impd-restore-saved-failures impd-restore-boundaries impd-restore-reset
```

Restored away from the host, 2026-10-16: the copy `imp-1.6.0-pre-2.0.3-20261015T214524` opened on a
scratch VM in 1.24 s ([the restore drill](./restore-drill.md#results)).

Checked read-only on geoffcloud, 2026-10-04: the image the script reads from a generation's
`imp-host.service` and the one `docker inspect` reports for the running imp-host are the same
digest-pinned string (`imp-host:0.29.0@sha256:4e6f0cf6…`), and so is the `image` line of the copy
`imp-0.29.0-consistent-20261003T181942`. **Untested:** any restore on geoffcloud.

**CAUTION:** Only copies with `COPY-INFO` are restorable. The copy taken before the 0.29.0 upgrade,
`imp-0.27.0-pre-0.29.0-20261003T171605`, is a tar copy without one, so the script refuses it and no
supported path returns the database to 0.27.0. Keep it on the host as legacy, unvalidated material:
do not add a `COPY-INFO` to it, and do not restore from it. The supported recovery point is the
integrity-checked copy `imp-0.29.0-consistent-20261003T181942` with a generation that runs the same
imp-host image. Before each imp upgrade, take a copy with `scripts/copy-impd-db.sh`; that copy is
the upgrade's rollback.

## 3. Roll the host back one generation

**Untested** as a recovery step. Generation switches forward are routine; no rollback has been
rehearsed. If imp's image changes, restore the matching database with section 2, which switches for
you; do not switch first.

```sh
ssh root@geoffcloud nixos-rebuild switch --rollback
```

Exception: imp 0.29.1 adds no migration to 0.29.0, so a rollback from 0.29.1 to the 0.29.0
generation needs no database restore. **CAUTION:** 0.29.0 holds the image.json flaw that 0.29.1
fixes (imp #196): a crafted imported image can overwrite host files. Before rolling back to 0.29.0,
stop all image imports and builds (`impz image add`, `impz image build`, templates from a new image,
BuildKit), and keep them stopped until a fixed imp runs again.

A rollback from 0.30.0 needs a database restore: 0.30.0 adds the migration
`021_add_broker_sessions`, and 0.29.1 refuses a database that holds it. Restore the copy
`pre-0.30.0-20261004T030409` with section 2; its generation runs 0.29.1 at the digest in its
`COPY-INFO`. **CAUTION:** the restore returns impd's database state only. It drops every metadata,
grant and token change impd made after 03:04Z on 2026-10-04 (UTC). It does not rewind disks,
checkpoints or images on the pool or the engine: those made later stay, and may need the
reconciliation that section 2's caution describes.

`nix-env -p /nix/var/nix/profiles/system --list-generations` lists the generations. If imp's version
changes, restore the matching database copy too (section 2).

## 4. Recover a lost disk

Follow [Recover a lost disk](./lost-disk.md). It holds three scenarios:

- **Lose `vda`:** restore an Onidel snapshot, or reinstall with the key from the 1Password item
  `zfs-tank-key` and the host's tailnet key in `--extra-files`. Everything on the pool survives.
- **Lose `vdb`:** recreate the pool and its two encryption roots, install the host's secret files
  from 1Password, start a new impd, restore the imps, add its secrets again, rebuild the agent
  image, mint new tokens, rebuild the cluster, and restore the gateway and nixie from restic.
- **Lose both:** reinstall, then follow the `vdb` steps.

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

**CAUTION:** With stack config `cluster: managed`, an empty `K3S_KUBECONFIG` stops the program
before it registers any resource (`infra/inputs/require-kubeconfig.ts`), so a run without the
kubeconfig fails instead of planning to delete the cluster. Never switch `cluster` to `none` to get
past it: that does plan to delete every cluster resource. Check the preview before any apply.

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

Follow [the gateway's backup and restore runbook](./atc-gateway-backup-restore.md).

## After any restore

- `https://imps.geoff.cloud/health` returns 200.
- Grafana's imp and cloudflared dashboards show current data.
- A refresh preview shows 0 changes (`bun run preview -- --refresh`).
