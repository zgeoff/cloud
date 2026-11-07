# nixie's backup

Use this runbook to back up nixie now, read its backup repositories, purge a forgotten item from old
snapshots, and test a restore. [nixie](./nixie.md) covers the service itself and a real restore.

nixie keeps its records in `nixie.db` and each record's key in `keys.db`, on its data volume. nixie
writes a backup set, a copy of both databases, into the `backup` folder of that volume every hour,
and at once after it forgets an item. Each set is a folder named by its sequence number, and nixie
writes a file named `complete` into it last.

The `nixie-backup` CronJob runs every night at 04:00 Melbourne time. Each run uploads every complete
set with restic, which encrypts it in the pod, to two repositories in R2:

| Repository | Path                                         | Holds      | Retention                                            |
| ---------- | -------------------------------------------- | ---------- | ---------------------------------------------------- |
| data       | `s3:<endpoint>/geoff-cloud-nixie/nixie`      | `nixie.db` | 24 hourly, 7 daily, 4 weekly and 6 monthly snapshots |
| key        | `s3:<endpoint>/geoff-cloud-nixie/nixie-keys` | `keys.db`  | the newest set's snapshot only                       |

After each upload to the key repository, the run prunes it with `--max-unused 0`, so restic deletes
the older sets' `keys.db` data at once. The run then writes a receipt, a file that records the
snapshots and each step's result, into each set, and deletes the set's two database copies. nixie
checks its `backup` folder on a poll, records each receipt it finds and deletes that set's folder.
nixie writes no new hourly set while a set waits for its receipt, so a set can wait up to a day for
the nightly run.

The key repository holds only the newest set's `keys.db`. Once the CronJob uploads the set that
nixie writes after it forgets an item, the key repository holds that item's key no longer. The data
repository's old snapshots tagged `nixie` are the exception, until you purge them as
[Purge a forgotten item from old snapshots](#purge-a-forgotten-item-from-old-snapshots) describes.

The CronJob runs the `nixie-backup` image from the same nixie release as `nixie.image`, pinned as
`nixie.backupImage` in `infra/Pulumi.prod.yaml`. The restore Job has two containers. Its `fetch`
container runs `deploy/nixie/backup/restore.sh` in the `nixie-backup` image, which restores
`keys.db` from the key repository and the `nixie.db` of the same set from the data repository. Its
`restore` container then runs `nixie restore` in nixie's own image, which replaces nixie's databases
with them.
[nixie's backups doc](https://github.com/zgeoff/nixie/blob/main/docs/architecture/deployment/backups.md)
gives the design of the sets, the receipts and the two repositories.

| Item in the `cloud` vault | Holds                                                |
| ------------------------- | ---------------------------------------------------- |
| `nixie-restic`            | the data repository's restic password                |
| `nixie-key-restic`        | the key repository's restic password                 |
| `r2-nixie-backup`         | the R2 key, endpoint and bucket of both repositories |

## Back up now

Run the CronJob twice to back up the current data. The first run uploads the set that waits, which
can be a day old. nixie then writes a fresh set, and the second run uploads it.

1. Start a run:

   ```bash
   job=nixie-backup-manual-$(date +%s)
   ssh root@geoffcloud k3s kubectl -n nixie create job --from=cronjob/nixie-backup "$job"
   ```

   Expect `job.batch/nixie-backup-manual-<seconds> created`.

2. Read the run's log:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie logs -f "job/$job"
   ```

   Expect one `"event":"backup.set_published"` line for each set the run uploads, with the set's
   `sequence`, and no `backup.set_failed` line. Note the highest `sequence`, or 0 when no set
   waited.

3. List the `backup` folder once a minute, until a set folder named with a higher sequence than step
   2's holds `complete`. nixie writes that set within the hour:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie exec nixie-0 -c nixie -- ls -R /data/backup
   ```

   Expect a folder such as `000000000042`, with `complete`, `keys.db`, `manifest.json` and
   `nixie.db` in it.

4. Run steps 1 and 2 again. Expect a `backup.set_published` line with the sequence of step 3.

## Read the repositories from a workstation

Run this helper from the root of a cloud checkout, with Docker, Bun and `op` signed in to the
`cloud` vault. It runs restic from the pinned `nixie-backup` image, with one repository's secrets
from 1Password. Pass `nixie` for the data repository or `nixie-keys` for the key repository.
`op run` resolves the references in the environment and masks them in the output:

```bash
nixie_restic() {
  local repo="$1" item
  shift
  item=$([ "$repo" = nixie-keys ] && echo nixie-key-restic || echo nixie-restic)
  RESTIC_PASSWORD="op://cloud/$item/password" \
    AWS_ACCESS_KEY_ID=op://cloud/r2-nixie-backup/access-key-id \
    AWS_SECRET_ACCESS_KEY=op://cloud/r2-nixie-backup/secret-access-key \
    op run -- docker run --rm -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    -e AWS_DEFAULT_REGION=auto --entrypoint restic \
    "$(bun -e 'console.log(Bun.YAML.parse(await Bun.file("infra/Pulumi.prod.yaml").text()).config["geoff-cloud:nixie"].backupImage)')" \
    -r "s3:$(op read op://cloud/r2-nixie-backup/endpoint)/geoff-cloud-nixie/$repo" "$@"
}
nixie_restic nixie snapshots
nixie_restic nixie-keys snapshots
```

Expect each set's snapshot tagged `set-<sequence>` and either `kind-scheduled` or `kind-forget`, and
one snapshot in the key repository. The data repository also lists snapshots tagged `nixie`, which
the next section covers.

## Purge a forgotten item from old snapshots

Each data snapshot tagged `nixie` holds both databases, `keys.db` included. The CronJob writes none
of them, and data retention deletes each one as it ages out. restic cannot delete one item from a
snapshot, so you delete each `nixie` snapshot taken before nixie forgot the item.

**CAUTION:** restic's `forget` and `prune` cannot be undone. They delete every restore point in the
snapshots you name, not only the forgotten item.

1. List the sets that nixie wrote at once after a forget:

   ```bash
   nixie_restic nixie snapshots --tag kind-forget
   ```

   Note the time of the first `kind-forget` snapshot after the item's forget. That set is the first
   one without the item's key.

2. List the old snapshots:

   ```bash
   nixie_restic nixie snapshots --tag nixie --host nixie
   ```

   Note the ID of each one older than the time of step 1.

3. Delete the snapshots of step 2. Then prune the repository:

   ```bash
   nixie_restic nixie forget <snapshot_id> <snapshot_id>
   nixie_restic nixie prune
   ```

   Expect `removed <n> snapshots` and prune's summary.

## Test a restore

The test restores the newest set into a scratch claim and starts a second nixie on it, while the
live nixie keeps running. The second nixie gets a config whose impd URL points at a dead port,
because the second nixie would otherwise reach impd and remove the live nixie's sandboxes at its
start. The second nixie opens both databases, runs its migrations and integrity check, and listens,
but never turns ready.

1. Create the scratch claim:

   ```bash
   ssh root@geoffcloud k3s kubectl create -f - < deploy/nixie/restore-check-claim.yaml
   ```

   Expect `persistentvolumeclaim/nixie-restore-check created`.

2. Create the restore Job on the scratch claim, with the live pod's image in place of `NIXIE_IMAGE`:

   ```bash
   image=$(ssh root@geoffcloud 'k3s kubectl -n nixie get pod nixie-0 -o "jsonpath={.spec.containers[?(@.name==\"nixie\")].image}"')
   sed -e 's/claimName: data-nixie-0/claimName: nixie-restore-check/' -e "s#NIXIE_IMAGE#$image#" \
     deploy/nixie/restore-job.yaml | ssh root@geoffcloud k3s kubectl create -f -
   ```

   Expect `job.batch/<job_name> created`, where `<job_name>` is `nixie-restore-` and a random
   suffix.

3. Read the `restore` container's log:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie logs job/<job_name> -c restore
   ```

   Expect the log to end with `nixie restored nixie.db and keys.db from /tmp/nixie-backup`.

4. Copy the live config into the ConfigMap `nixie-restore-check`, with impd's URL pointed at a dead
   port. `deploy/nixie/config.yaml` lacks the `imp` section, which infra adds from
   `packages/topology`, so the step copies the live ConfigMap. ssh joins its arguments into one
   remote command, so a command whose remote part holds JSONPath quotes that whole part:

   ```bash
   config=$(ssh root@geoffcloud 'k3s kubectl -n nixie get pod nixie-0 -o "jsonpath={.spec.volumes[?(@.name==\"config\")].configMap.name}"')
   ssh root@geoffcloud "k3s kubectl -n nixie get configmap $config -o 'jsonpath={.data.config\.yaml}'" \
     | sed 's#"url":"https://imps.geoff.cloud"#"url":"http://127.0.0.1:1"#' \
     | ssh root@geoffcloud k3s kubectl -n nixie create configmap nixie-restore-check --from-file=config.yaml=/dev/stdin
   ```

   Expect `configmap/nixie-restore-check created`.

5. Check that the copy points at the dead port before any nixie reads it:

   ```bash
   ssh root@geoffcloud "k3s kubectl -n nixie get configmap nixie-restore-check -o 'jsonpath={.data.config\.yaml}'" \
     | grep -o '"url":"[^"]*"'
   ```

   Expect `"url":"http://127.0.0.1:1"` alone. With any other URL, stop: remove the ConfigMap as in
   step 8, and start nothing.

6. Start the scratch nixie, with the image of step 2 and the live Secret:

   ```bash
   secrets=$(ssh root@geoffcloud 'k3s kubectl -n nixie get pod nixie-0 -o "jsonpath={.spec.volumes[?(@.name==\"secrets\")].secret.secretName}"')
   sed -e "s#NIXIE_IMAGE#$image#" -e "s#NIXIE_SECRETS#$secrets#" deploy/nixie/restore-check-pod.yaml \
     | ssh root@geoffcloud k3s kubectl create -f -
   ```

   Expect `pod/nixie-restore-check created`.

7. Check that it started:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie logs nixie-restore-check | grep -E '"(writer.started|http.listening)"'
   ssh root@geoffcloud k3s kubectl -n nixie exec nixie-restore-check -- nixie health --live && echo live
   ```

   Expect a `writer.started` line with the schema version, an `http.listening` line, the liveness
   report, and `live`.

8. Remove the scratch nixie, its ConfigMap, the claim and the restore Job. When a step failed, name
   only the objects that the steps before it created:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie delete pod/nixie-restore-check configmap/nixie-restore-check pvc/nixie-restore-check job/<job_name>
   ```

   Expect one `deleted` line for each object.
