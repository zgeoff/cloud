# The files service

The files service runs `files.geoff.cloud`, the file drop for agents' PR screenshots and the owner's
own files. It runs as the `files` StatefulSet in k3s, on a retained local-path volume that holds the
files and their SQLite metadata. Two role tokens, `agent` and `owner`, gate every write; the cluster
holds only their SHA-256 hashes. The `files-backup` CronJob backs the volume up every night with
restic to a `files` repository in R2. Setting the stack config `files` approves the deploy, and
leaving it unset keeps the service out of the cluster.

## What holds what

| Item in the `cloud` vault | Holds                                                    | Read by            |
| ------------------------- | -------------------------------------------------------- | ------------------ |
| `files-agent-token`       | the `agent` token, which every agent shares              | Pulumi, agents     |
| `files-owner-token`       | the `owner` token                                        | Pulumi, the owner  |
| `files-restic`            | the restic repository's password                         | Pulumi, the backup |
| `r2-files-backup`         | the R2 key, endpoint and bucket of the restic repository | Pulumi, the backup |

The prod apply job reads the same items from the `cloud-deploy` vault, so each item has a copy there
under the same name. Agents read their copy of the agent token from the `imp` vault on an imp, and
from the `zgeoff` vault on a workstation.

## Deploy the first time

1. Merge the service. The `files image` workflow publishes `ghcr.io/zgeoff/cloud-files:<commit>`
   from `main`, and its run summary gives the digest.
2. Create the four items in the `cloud` vault, then copy each into `cloud-deploy`. Mint each token
   as 32 random bytes in hex:

   ```bash
   openssl rand -hex 32
   ```

   Copy the agent token into the `imp` and `zgeoff` vaults.

3. In a PR, add the references to `.env` and the `files` object to `infra/Pulumi.prod.yaml`:

   ```bash
   FILES_AGENT_TOKEN=op://cloud/files-agent-token/credential
   FILES_OWNER_TOKEN=op://cloud/files-owner-token/credential
   FILES_RESTIC_PASSWORD=op://cloud/files-restic/password
   FILES_R2_ACCESS_KEY_ID=op://cloud/r2-files-backup/access-key-id
   FILES_R2_SECRET_ACCESS_KEY=op://cloud/r2-files-backup/secret-access-key
   FILES_R2_ENDPOINT=op://cloud/r2-files-backup/endpoint
   FILES_R2_BUCKET=op://cloud/r2-files-backup/bucket
   ```

   ```yaml
   geoff-cloud:files:
     image: ghcr.io/zgeoff/cloud-files:<commit>@sha256:<digest>
     hostname: files.geoff.cloud
   ```

   Run `bun run preview` and check that it adds the `files` namespace, its Secrets, Service,
   StatefulSet and backup CronJob, and changes nothing else.

4. Merge the PR, and approve the held `Deploy prod` run once its plan matches the preview.
5. Check that the pod is up:

   ```bash
   ssh root@geoffcloud k3s kubectl -n files rollout status statefulset/files --timeout=300s
   ```

   Expect `statefulset rolling update complete`.

## Upload a file

An agent on an imp uploads with `curl`, which sends the token as a bearer token:

```bash
FILES_TOKEN="$(op read op://imp/files-agent-token/credential)"
curl -sS --oauth2-bearer "$FILES_TOKEN" -F file=@shot.png -F expires=7d \
  https://files.geoff.cloud/api/files
```

Expect a JSON body with the file's `url`. `expires` takes `7d` (the default), `30d`, a date such as
`2026-12-01`, or `never` with the owner token.

## Upgrade the service

1. Merge the change. The `files image` workflow publishes the new commit's image.
2. In a PR, set `files.image` in `infra/Pulumi.prod.yaml` to the new tag and digest.
3. Merge it. `Deploy prod` rolls `files-0`; the service is down for the restart.

## Revoke a token

1. Mint a new value with `openssl rand -hex 32`, and put it in the item in `cloud` and in each copy:
   `cloud-deploy`, and for the agent token `imp` and `zgeoff`.
2. [Apply by hand](./workflows.md#apply-by-hand) from `main`. The `Deploy prod` job applies only a
   new commit, so it never runs for a change in 1Password alone. Both drift checks and the preview
   show one change: Pulumi replaces the hash Secret `files-tokens`. Expect nothing else.
3. The new Secret rolls `files-0`, and the old token stops working once the new pod is ready.
   Existing uploads stay.

## Back up now

```bash
ssh root@geoffcloud k3s kubectl -n files create job --from=cronjob/files-backup files-backup-manual-$(date +%s)
ssh root@geoffcloud k3s kubectl -n files logs -f job/<job-name>
```

Expect the log to end with restic's retention table and `snapshot <id> saved` above it.

## Restore from a backup

`deploy/files/restore-job.yaml` restores the volume from a snapshot. It checks the snapshot's copy
of the metadata before it changes anything, restores the files, replaces the metadata and its WAL,
and removes each file that the restored metadata does not list.

**CAUTION:** A restore replaces the metadata with the snapshot's. Every upload made after the
snapshot is lost. Back up first if those uploads still matter.

1. Stop the service, so nothing writes during the restore:

   ```bash
   ssh root@geoffcloud k3s kubectl -n files scale statefulset/files --replicas=0
   ssh root@geoffcloud k3s kubectl -n files wait --for=delete pod/files-0 --timeout=120s
   ```

   Expect `pod/files-0 condition met`.

2. Restore. Set `args: ["ls"]` in the Job to list the snapshots first, and `SNAPSHOT` to pick one:

   ```bash
   ssh root@geoffcloud k3s kubectl create -f - < deploy/files/restore-job.yaml
   ssh root@geoffcloud k3s kubectl -n files logs -f job/<job-name>
   ```

   Expect `restored files.db: integrity_check ok, <n> uploads, <m> files without a row removed`.

3. Start the service, and check that an uploaded file serves again:

   ```bash
   ssh root@geoffcloud k3s kubectl -n files scale statefulset/files --replicas=1
   curl -sS -o /dev/null -w '%{http_code}\n' https://files.geoff.cloud/<id>/<filename>
   ```

   Expect `200` for an upload the snapshot holds that has not expired.

## Check a restore

The check restores the latest snapshot into a scratch claim, so the live volume and the service stay
as they are.

1. Create the scratch claim:

   ```bash
   ssh root@geoffcloud k3s kubectl -n files create -f - << 'EOF'
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: files-restore-check
   spec:
     accessModes: [ReadWriteOnce]
     storageClassName: local-path
     resources:
       requests:
         storage: 20Gi
   EOF
   ```

2. Run the restore Job against it:

   ```bash
   sed 's/claimName: data-files-0/claimName: files-restore-check/' deploy/files/restore-job.yaml |
     ssh root@geoffcloud k3s kubectl create -f -
   ssh root@geoffcloud k3s kubectl -n files logs -f job/<job-name>
   ```

   Expect `restored files.db: integrity_check ok, <n> uploads, 0 files without a row removed`. The
   snapshot holds every upload that existed at its time, expired ones included, so `<n>` differs
   from today's list by the uploads made, removed or swept since. Record `<n>` rather than match it.

3. Delete the Job and the scratch claim:

   ```bash
   ssh root@geoffcloud k3s kubectl -n files delete job/<job-name> pvc/files-restore-check
   ```

4. Record the check, with the snapshot ID and the counts, on the issue that asked for it.
