# atc-gateway: backup and restore

The gateway's durable state is two SQLite files on its volume. This runbook covers what is backed
up, where, and how to restore it. The procedure is tested by `e2e/test-atc-gateway-restore.sh` and
`deploy/atc-gateway/backup/test-backup.sh` against a local restic repository; it has not run against
R2 or k3s yet.

## Data boundary

| Data                                                                         | Where it lives                                                | Backed up by this runbook                   | Secret-bearing |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------- | -------------- |
| `mcp-auth.db`: OAuth clients, consents, grants, token records                | gateway volume (`atc-gateway-state` claim)                    | yes                                         | yes            |
| `gateway.db`: daemon registry, event cursors, daemon token hashes (atc's PR) | gateway volume                                                | yes                                         | yes            |
| daemon bearer tokens, impd token, restic password, R2 keys                   | 1Password `cloud` vault → k8s Secrets / host credential files | no: 1Password is the source                 | yes            |
| daemon registry entries (non-secret)                                         | stack config → ConfigMap                                      | no: the repo is the source                  | no             |
| harness imps and their disks                                                 | imp's ZFS pool on geoffcloud                                  | no: imp's own restic backups (`imp backup`) | per imp        |
| atc's daemon state on geoffcloud                                             | `/var/lib/atc-daemon` on the root disk                        | no (decide with atc's daemon PR)            | possibly       |

Rules:

- The backup takes only `*.db` files from the volume, each copied with `sqlite3 .backup` and checked
  with `PRAGMA integrity_check` before upload. Nothing else on the volume is uploaded.
- restic encrypts on the cluster before upload, with a password that lives only in 1Password and the
  backup Secret. R2 holds ciphertext.
- Credentials are never in a backup. A restore needs 1Password for the restic password.
- The root disk, and so the volume, is also in the Onidel VM snapshots, in plain form, behind the
  Onidel account. That is a separate, account-protected copy; this runbook does not rely on it.

## Where

- Repository: `s3:<r2-endpoint>/<bucket>/atc-gateway/geoffcloud`. The bucket is an approval
  decision: a new bucket with its own R2 key (narrow), or `geoff-cloud-backups` with the existing
  key (broad, since that key also reaches imp's backups).
- Schedule: the `atc-gateway-backup` CronJob, 03:30 Australia/Melbourne, retention 7 daily and 4
  weekly snapshots.
- Image: `ghcr.io/zgeoff/atc-gateway-backup` (restic 0.18.1 plus sqlite3), pinned by digest.

## Back up now

```sh
ssh root@geoffcloud k3s kubectl -n atc create job --from=cronjob/atc-gateway-backup backup-manual-$(date +%s)
ssh root@geoffcloud k3s kubectl -n atc logs -f job/<job-name>
```

## Restore

**CAUTION:** A restore replaces the gateway's OAuth state. Every grant issued after the snapshot is
lost: those clients sign in again. Take a fresh backup first if the current state still matters.

1. Stop the gateway, so nothing writes during the restore:

   ```sh
   ssh root@geoffcloud k3s kubectl -n atc scale deploy/atc-gateway --replicas=0
   ```

2. Restore with `deploy/atc-gateway/restore-job.yaml`. Set its image digest. To list snapshots
   first, set `args: ["ls"]`; to pick one, set `SNAPSHOT`. The script restores into a scratch
   directory, checks each database's integrity, and only then replaces the files, including any
   `-wal` and `-shm`:

   ```sh
   ssh root@geoffcloud k3s kubectl create -f - < deploy/atc-gateway/restore-job.yaml
   ssh root@geoffcloud k3s kubectl -n atc logs -f job/<job-name>
   ```

3. Start the gateway and check it:

   ```sh
   ssh root@geoffcloud k3s kubectl -n atc scale deploy/atc-gateway --replicas=1
   bash scripts/check-atc-gateway-readiness.sh
   ```

4. Record the restore (snapshot ID, time, why) in a cloud issue.

## Restore test

Before the gateway carries real clients, run one restore into a scratch claim and confirm the
gateway starts on it and lists its OAuth clients. The fixture test does the same locally on every
change to the images.
