# pepys: the backup

Give the backup of [pepys](../architecture/workloads/pepys.md) the Garage key it reads with, and run
a backup on demand. Use [Give the backup its Garage key](#give-the-backup-its-garage-key) before the
first backup, and again whenever Garage's `meta` volume is new. Use [Back up now](#back-up-now) to
copy the buckets outside the daily schedule.
[Secrets and the backup](../architecture/workloads/pepys.md#secrets-and-the-backup) explains what
the backup copies and where.

## Give the backup its Garage key

The cluster runs the backup only while `.env` holds every `PEPYS_BACKUP_*` and `PEPYS_R2_*`
variable. Without them, the Pulumi program adds no backup CronJob.

Import the backup's key into Garage before the first backup, and again whenever Garage's `meta`
volume is new, such as after a rebuild of Garage's data. Garage creates the key of s2-lite, the fact
log's server, at each start, but Garage never creates the backup's key. Without the key, the backup
fails with `AccessDenied`.

The 1Password item `pepys-garage-backup` holds the key in two fields, `access-key-id` and
`secret-access-key`. [The prod apply job](./prod-apply.md) reads its copy in the `cloud-deploy`
vault, so the item lives in the vaults `cloud` and `cloud-deploy` under the same name. The key can
read each bucket that `pepysWorkloads.backup.buckets` in
[`pepys-workloads.ts`](../../infra/shared/pepys-workloads.ts) lists, and write none.

1. If the item does not exist, mint a key and store it in both vaults. The key ID is `GK` and 24 hex
   digits, and the secret is 64 hex digits. The item goes to `op` on stdin:

   ```sh
   item="$(jq -n --arg id "GK$(openssl rand -hex 12)" --arg secret "$(openssl rand -hex 32)" \
     '{title: "pepys-garage-backup", category: "API_CREDENTIAL", fields: [
       {id: "access-key-id", label: "access-key-id", type: "STRING", value: $id},
       {id: "secret-access-key", label: "secret-access-key", type: "CONCEALED", value: $secret}]}')"
   printf '%s' "$item" | op item create --vault cloud > /dev/null
   printf '%s' "$item" | op item create --vault cloud-deploy > /dev/null
   unset item
   ```

   Expect `op item get pepys-garage-backup --vault cloud-deploy` to list both fields.

2. Import the key into Garage. `garage key import` takes the secret as an argument, and the host's
   journal records the SSH command line, so send the command as a script on SSH's stdin:

   ```sh
   printf 'k3s kubectl -n pepys exec pepys-garage-0 -c garage -- /garage key import --yes -n pepys-backup %s %s > /dev/null\n' \
     "$(op read op://cloud/pepys-garage-backup/access-key-id)" \
     "$(op read op://cloud/pepys-garage-backup/secret-access-key)" \
     | ssh root@geoffcloud bash -s
   ```

   Expect Garage's `INFO` connection lines and no error. When Garage already holds the key, the
   import fails with `KeyAlreadyExists` and changes nothing, so go on to the next step.

3. Give the key read access to each bucket that the backup copies. For `facts`:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys exec pepys-garage-0 -c garage -- \
     /garage bucket allow --read facts --key pepys-backup
   ```

   Expect the command to print the bucket's key table, with `R` for `pepys-backup` and `RWO` for
   s2-lite's `default access key`. Running it again changes nothing.

4. Run the backup once, as [Back up now](#back-up-now) describes.

## Back up now

1. Start a job from the backup's CronJob:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys create job --from=cronjob/pepys-backup pepys-backup-manual-$(date +%s)
   ```

   Expect `job.batch/<job-name> created`, where `<job-name>` is the new job's name.

2. Follow the job's log:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys logs -f job/<job-name>
   ```

   Expect one `copied <bucket>` line for each bucket, such as `copied facts`. When the log shows
   `AccessDenied` from Garage, [give the backup its Garage key](#give-the-backup-its-garage-key).
