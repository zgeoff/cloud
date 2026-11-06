# nixie's backup

nixie stages a backup set of its two databases in the `backup` folder of its data volume, on its
backup interval and at once after a forget. The `nixie-backup` CronJob runs every night at 04:00
Melbourne time in the `nixie-backup` image of nixie's own release, pinned as `nixie.backupImage` in
`infra/Pulumi.prod.yaml`. The image's job ships each waiting set with restic to two repositories in
R2, encrypted on the cluster:

| Repository | Path                                         | Holds              | Retention                                         |
| ---------- | -------------------------------------------- | ------------------ | ------------------------------------------------- |
| data       | `s3:<endpoint>/geoff-cloud-nixie/nixie`      | `nixie.db` per set | 24 hourly, 7 daily, 4 weekly and 6 monthly        |
| key        | `s3:<endpoint>/geoff-cloud-nixie/nixie-keys` | `keys.db` per set  | the newest set alone, pruned of every unused byte |

The job writes a receipt into each set and removes the set's copies, and nixie records the receipt
on its next pass and removes the set's folder. Because the key repository keeps one set, a forgotten
item's key leaves every backup at the first set after the forget.
[nixie's backups doc](https://github.com/zgeoff/nixie/blob/main/docs/architecture/deployment/backups.md)
describes the sets, the job and the receipts. nixie stages no new scheduled set while one waits for
its receipt, so a set waits on the volume for up to a day.

The restore Job runs `deploy/nixie/backup/restore.sh` in the same image. It restores `keys.db` from
the key repository and the `nixie.db` of the same set from the data repository, and `nixie restore`
replaces nixie's databases with them. The vault items `nixie-restic`, `nixie-key-restic` and
`r2-nixie-backup` hold the data repository's password, the key repository's password and the R2 key.
[nixie](./nixie.md#restore-from-a-backup) gives a real restore.

## Back up now

A run of the job ships the sets that wait. When nixie has recorded the receipt, its next pass stages
a fresh set, and a second run ships it.

1. Run the job, and read its log:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie create job --from=cronjob/nixie-backup nixie-backup-manual-$(date +%s)
   ssh root@geoffcloud k3s kubectl -n nixie logs -f job/<job-name>
   ```

   Expect a `"event":"backup.set_published"` line with the set's `sequence` for each set it ships,
   and no `backup.set_failed` line.

2. List the staging folder until a set with a higher sequence than step 1's holds a `complete`
   marker:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie exec nixie-0 -c nixie -- ls -R /data/backup
   ```

3. Run step 1 again. Expect a `backup.set_published` line with that higher sequence.

## Read the repositories from a workstation

This helper runs restic from the pinned `nixie-backup` image, with one repository's secrets from
1Password. Pass `nixie` for the data repository or `nixie-keys` for the key repository. `op run`
resolves the references in the environment and masks them in the output:

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

Expect each set's snapshot tagged `set-<sequence>` and `kind-scheduled` or `kind-forget`, and one
snapshot in the key repository.

## Purge a forgotten item

The data repository also holds the snapshots of the job that copied both databases whole into one
snapshot, tagged `nixie`, so each of them holds `keys.db`. restic cannot drop one item from a
snapshot. The purge forgets every such snapshot taken before nixie's forget instead.

**CAUTION:** A forget cannot be undone. It removes every restore point older than nixie's forget in
those snapshots, not only the forgotten item.

1. List them with `nixie_restic nixie snapshots --tag nixie --host nixie`, and note each ID older
   than nixie's forget.
2. Forget them and prune:

   ```bash
   nixie_restic nixie forget <snapshot_id> <snapshot_id>
   nixie_restic nixie prune
   ```

   Expect `removed <n> snapshots` and prune's summary.

## Test a restore

The test restores the newest set into a scratch claim and starts a second nixie on it, while the
live nixie keeps running. The second nixie has impd's address pointed at a dead port, because its
recovery would otherwise remove the live nixie's sandboxes. It opens both databases, runs its
migrations and integrity check, and listens, but never turns ready.

1. Create the scratch claim, and restore into it with `claimName: nixie-restore-check` and the live
   pod's image in `deploy/nixie/restore-job.yaml`:

   ```bash
   ssh root@geoffcloud k3s kubectl create -f - < deploy/nixie/restore-check-claim.yaml
   image=$(ssh root@geoffcloud 'k3s kubectl -n nixie get pod nixie-0 -o "jsonpath={.spec.containers[?(@.name==\"nixie\")].image}"')
   sed -e 's/claimName: data-nixie-0/claimName: nixie-restore-check/' -e "s#NIXIE_IMAGE#$image#" \
     deploy/nixie/restore-job.yaml | ssh root@geoffcloud k3s kubectl create -f -
   ssh root@geoffcloud k3s kubectl -n nixie logs job/<job-name> -c restore
   ```

   Expect `nixie restored nixie.db and keys.db from /tmp/nixie-backup`.

2. Start the scratch nixie, with the live pod's config, the image of step 1, and the live Secret.
   The config is the live ConfigMap's, because infra adds its `imp` section from
   `packages/topology`, with impd's URL pointed at a dead port. ssh joins its arguments into one
   remote command, so each command quotes the whole of it, JSONPath included:

   ```bash
   config=$(ssh root@geoffcloud 'k3s kubectl -n nixie get pod nixie-0 -o "jsonpath={.spec.volumes[?(@.name==\"config\")].configMap.name}"')
   ssh root@geoffcloud "k3s kubectl -n nixie get configmap $config -o 'jsonpath={.data.config\.yaml}'" \
     | sed 's#"url":"https://imps.geoff.cloud"#"url":"http://127.0.0.1:1"#' \
     | ssh root@geoffcloud k3s kubectl -n nixie create configmap nixie-restore-check --from-file=config.yaml=/dev/stdin
   secrets=$(ssh root@geoffcloud 'k3s kubectl -n nixie get pod nixie-0 -o "jsonpath={.spec.volumes[?(@.name==\"secrets\")].secret.secretName}"')
   sed -e "s#NIXIE_IMAGE#$image#" -e "s#NIXIE_SECRETS#$secrets#" deploy/nixie/restore-check-pod.yaml \
     | ssh root@geoffcloud k3s kubectl create -f -
   ```

3. Check that it started:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie logs nixie-restore-check | grep -E '"(writer.started|http.listening)"'
   ssh root@geoffcloud k3s kubectl -n nixie exec nixie-restore-check -- nixie health --live && echo live
   ```

   Expect a `writer.started` line with the schema version, an `http.listening` line, the liveness
   report, and `live`.

4. Remove the scratch nixie, its ConfigMap, the claim, and the restore Job:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie delete pod/nixie-restore-check configmap/nixie-restore-check pvc/nixie-restore-check job/<job-name>
   ```
