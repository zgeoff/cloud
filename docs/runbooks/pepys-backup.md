# pepys: the backup

Give the backup of [pepys](../architecture/workloads/pepys.md) its key to Garage, and run a backup
on demand. Garage is the bucket store in the `pepys` namespace, and the backup copies Garage's
buckets to R2 each day. Use [Give the backup its Garage key](#give-the-backup-its-garage-key) before
the first backup, and again after Garage loses its keys. Use [Back up now](#back-up-now) to copy the
buckets outside the daily schedule.
[Secrets and the backup](../architecture/workloads/pepys.md#secrets-and-the-backup) explains what
the backup copies and where.

## Give the backup its Garage key

Garage keeps its keys on its `meta` volume, and it creates only the key of s2-lite, the server of
the fact log, at each start. An operator imports the backup's key by hand. A `meta` volume that
starts empty, such as after a rebuild of Garage's data, holds no backup key, and the backup then
fails with `AccessDenied`.

The 1Password item `pepys-garage-backup` holds the key in two fields, `access-key-id` and
`secret-access-key`. The item lives under the same name in two vaults: `cloud`, which these steps
read, and `cloud-deploy`, which [the prod apply job](./prod-apply.md) reads to give the backup's pod
the key.

The Pulumi program adds the backup CronJob only while the repo's root `.env` names every
`PEPYS_BACKUP_*` and `PEPYS_R2_*` variable. The steps below do not need the CronJob, except the
last.

1. Check whether the item exists in each vault:

   ```sh
   op item get pepys-garage-backup --vault cloud --fields label=access-key-id
   op item get pepys-garage-backup --vault cloud-deploy --fields label=access-key-id
   ```

   When both commands print the same key ID, go to step 3. When neither vault holds the item, go on
   to step 2. When one vault alone holds the item, create the item in the other vault with the same
   two values, then go to step 3.

2. Mint a key. Store it in both vaults. The key ID is `GK` and 24 hex digits, and the secret is 64
   hex digits. The commands send the item to `op` on stdin:

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

3. Import the key into Garage.

   **CAUTION:** `garage key import` takes the secret as an argument, and the host's journal records
   the SSH command line. Send the command as a script on SSH's stdin, as the command below does.

   ```sh
   printf 'k3s kubectl -n pepys exec pepys-garage-0 -c garage -- /garage key import --yes -n pepys-backup %s %s > /dev/null\n' \
     "$(op read op://cloud/pepys-garage-backup/access-key-id)" \
     "$(op read op://cloud/pepys-garage-backup/secret-access-key)" \
     | ssh root@geoffcloud bash -s
   ```

   Expect Garage's `INFO` connection lines on stderr, and no error. When Garage already holds the
   key, the import fails with `KeyAlreadyExists` and changes nothing, so go on to the next step.

4. Give the key read access to each bucket that the backup copies. `pepysWorkloads.backup.buckets`
   in [`pepys-workloads.ts`](../../infra/shared/pepys-workloads.ts) lists the buckets. Run the
   command once for each bucket, with the bucket's name in place of `facts`:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys exec pepys-garage-0 -c garage -- \
     /garage bucket allow --read facts --key pepys-backup
   ```

   Expect the command to print the bucket's key table, with `R` for `pepys-backup` and `RWO` for
   s2-lite's `default access key`. Running it again changes nothing. The key then reads each bucket
   that the backup copies, and writes none.

5. Run the backup once, as [Back up now](#back-up-now) describes.

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
