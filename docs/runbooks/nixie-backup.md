# nixie's backup

The `nixie-backup` CronJob backs up nixie's data every night with restic, encrypted on the cluster,
to the repository `s3:<endpoint>/geoff-cloud-nixie/nixie` in R2. Its first container runs nixie's
own `nixie backup` command, from the running nixie's image, against nixie's volume while nixie runs.
The command writes a matching copy of nixie's databases into a directory the pod shares, and restic
uploads that directory and nothing else. Only nixie's command opens nixie's files, and
[nixie's host commands](https://github.com/zgeoff/nixie/blob/main/docs/architecture/deployment/host-commands.md#backup-and-restore)
describe how it keeps the two databases matched. The restore Job runs the same two steps in reverse:
restic restores a snapshot into the shared directory, and `nixie restore` replaces nixie's databases
with it. The vault items `nixie-restic` and `r2-nixie-backup` hold the repository's password and R2
key. [nixie](./nixie.md#restore-from-a-backup) gives a real restore.

## Back up now

```bash
ssh root@geoffcloud k3s kubectl -n nixie create job --from=cronjob/nixie-backup nixie-backup-manual-$(date +%s)
ssh root@geoffcloud k3s kubectl -n nixie logs -f job/<job-name>
```

Expect the log to end with restic's retention table and `snapshot <id> saved` above it.

## Read the repository from a workstation

This helper runs the pinned restic image with the repository's secrets from 1Password. `op run`
resolves the references in the environment and masks them in the output:

```bash
nixie_restic() {
  RESTIC_PASSWORD=op://cloud/nixie-restic/password \
    AWS_ACCESS_KEY_ID=op://cloud/r2-nixie-backup/access-key-id \
    AWS_SECRET_ACCESS_KEY=op://cloud/r2-nixie-backup/secret-access-key \
    op run -- docker run --rm -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    -e AWS_DEFAULT_REGION=auto restic/restic:0.18.1 \
    -r "s3:$(op read op://cloud/r2-nixie-backup/endpoint)/geoff-cloud-nixie/nixie" "$@"
}
nixie_restic snapshots --tag nixie --host nixie
```

## Purge a forgotten item

Each snapshot holds both databases whole, so restic cannot drop one item from it. The purge forgets
every snapshot taken before nixie's forget instead.

**CAUTION:** A forget cannot be undone. It removes every restore point older than the backup in step
1, not only the forgotten item.

1. Back up now, as above, so the newest snapshot postdates nixie's forget.
2. List the snapshots with `nixie_restic snapshots --tag nixie --host nixie`, and note each ID older
   than nixie's forget.
3. Forget them and prune:

   ```bash
   nixie_restic forget <snapshot_id> <snapshot_id>
   nixie_restic prune
   ```

   Expect `removed <n> snapshots` and prune's summary.

## Test a restore

The test restores the latest snapshot into a scratch claim and starts a second nixie on it, while
the live nixie keeps running. The second nixie has impd's address pointed at a dead port, because
its recovery would otherwise remove the live nixie's sandboxes. It opens both databases, runs its
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
