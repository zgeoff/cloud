# The boxxy server

The boxxy server runs as the `boxxy` StatefulSet in k3s, on a retained local-path volume that holds
its SQLite store. The `boxxy-backup` CronJob backs the store up every night with restic to a `boxxy`
repository in R2. Setting the stack config `boxxy` approves the deploy, and leaving it unset keeps
the server out of the cluster. [The workload doc](../architecture/workloads/boxxy.md) covers the
listeners, the configuration and the caller proof.

## What holds what

| Item in the `cloud` vault | Holds                                                    | Read by               |
| ------------------------- | -------------------------------------------------------- | --------------------- |
| `boxxy-worker-token`      | the worker token, which the broker adds to worker calls  | Pulumi, impd's broker |
| `boxxy-atc-token`         | the bearer token the server sends to the atc gateway     | Pulumi                |
| `boxxy-restic`            | the restic repository's password                         | Pulumi, the backup    |
| `r2-boxxy-backup`         | the R2 key, endpoint and bucket of the restic repository | Pulumi, the backup    |

The prod apply job reads the same items from the `cloud-deploy` vault, so each item has a copy there
under the same name. A `.env` line whose item is missing fails every preview and apply, so create
the items, with their copies, before the PR that adds the lines merges.

## Deploy the first time

1. Merge the server. The `boxxy image` workflow publishes `ghcr.io/zgeoff/cloud-boxxy:<commit>` from
   `main`, and its run summary gives the digest.
2. Create the four items in the `cloud` vault, then copy each into `cloud-deploy`. Mint the worker
   token as 32 random bytes in hex:

   ```bash
   openssl rand -hex 32
   ```

3. In a PR, add the references to `.env` and the `boxxy` object to `infra/Pulumi.prod.yaml`:

   ```bash
   BOXXY_WORKER_TOKEN=op://cloud/boxxy-worker-token/credential
   BOXXY_ATC_TOKEN=op://cloud/boxxy-atc-token/credential
   BOXXY_RESTIC_PASSWORD=op://cloud/boxxy-restic/password
   BOXXY_R2_ACCESS_KEY_ID=op://cloud/r2-boxxy-backup/access-key-id
   BOXXY_R2_SECRET_ACCESS_KEY=op://cloud/r2-boxxy-backup/secret-access-key
   BOXXY_R2_ENDPOINT=op://cloud/r2-boxxy-backup/endpoint
   BOXXY_R2_BUCKET=op://cloud/r2-boxxy-backup/bucket
   ```

   ```yaml
   geoff-cloud:boxxy:
     image: ghcr.io/zgeoff/cloud-boxxy:<commit>@sha256:<digest>
     runner: geoffcloud
     atc:
       trustedFolders: {}
     spawn:
       target: geoffcloud
   ```

   Set the repos as the secret stack config `boxxySpawnRepos`, so no repo name reaches the public
   file. Write the JSON to a file outside the repo, and pass it on stdin, so the names stay out of
   the shell history:

   ```json
   { "<owner>/<repo>": { "url": "https://github.com/<owner>/<repo>", "ref": "<branch>" } }
   ```

   ```bash
   cd infra
   op run --env-file=../.env -- pulumi config set --stack prod --secret boxxySpawnRepos < <file of JSON>
   ```

   Check that the diff of `infra/Pulumi.prod.yaml` adds only a `secure:` value under
   `geoff-cloud:boxxySpawnRepos`. Each imp is a fresh machine, so each repo is a git source that atc
   clones in the imp over the imp's own network. The broker adds the GitHub credential from the
   session's grants, so the URL carries none, and the server skips the trusted-folder check for a
   git source.

   The image must hold a server that calls atc over MCP. Leave out the `BOXXY_RESTIC_*` and
   `BOXXY_R2_*` lines until both of their items exist: the backup takes all five variables or none,
   and one alone fails the preview.

   Run `bun run preview` and check that it adds the `boxxy` namespace, its Secrets, both ConfigMaps,
   both Services, both NetworkPolicies, the StatefulSet, and the backup Secret and CronJob, and
   changes nothing else. Without the `BOXXY_RESTIC_*` and `BOXXY_R2_*` variables, the server deploys
   with no backup.

4. Merge the PR. `Deploy prod` applies it, since every step is a create.
5. Check that the pod is up and both listeners started:

   ```bash
   ssh root@geoffcloud k3s kubectl -n boxxy rollout status statefulset/boxxy --timeout=300s
   ssh root@geoffcloud k3s kubectl -n boxxy logs boxxy-0 | grep 'boxxy server listening'
   ```

   Expect `statefulset rolling update complete`, then one line with `"ownerPort":8090` and
   `"workerPort":8091`.

## Reach the owner listener

The owner listener has no route, so forward its port through SSH and leave the command running:

```bash
ssh -L 8090:localhost:8090 root@geoffcloud k3s kubectl -n boxxy port-forward svc/boxxy 8090
```

Then set `BOXXY_URL=http://localhost:8090` for the boxxy CLI.

## Add a trust document

1. Write the impd's document, as `impz identity jwks` prints it on that impd's host, to
   `deploy/boxxy/issuers/<issuer>.json`.
2. Merge it in a PR. The preview shows the new `boxxy-issuers` ConfigMap, a new `boxxy-config`
   ConfigMap that gains the `trustedIssuers` section, and an update of the StatefulSet. The pod
   rolls, and session and hook calls from that impd's imps pass the caller proof.

## Upgrade the server

1. Merge the change: a new `@boxxy/server` version in `package.json` and `bun.lock`, or a change to
   `deploy/boxxy/`. The `boxxy image` workflow publishes the new commit's image.
2. In a PR, set `boxxy.image` in `infra/Pulumi.prod.yaml` to the new tag and digest.
3. Merge it. `Deploy prod` rolls `boxxy-0`; the server is down for the restart.

## Rotate a token

1. Mint a new value with `openssl rand -hex 32`, and put it in the item in `cloud` and in its
   `cloud-deploy` copy. For the worker token, also replace impd's `boxxy` secret.
2. [Apply by hand](./workflows.md#apply-by-hand) from `main`. The `Deploy prod` job applies only a
   new commit, so it never runs for a change in 1Password alone. Both drift checks and the preview
   show one change: Pulumi replaces the Secret `boxxy-tokens`. Expect nothing else.
3. The new Secret rolls `boxxy-0`, and the old token stops working once the new pod is ready.

## Back up now

```bash
ssh root@geoffcloud k3s kubectl -n boxxy create job --from=cronjob/boxxy-backup boxxy-backup-manual-$(date +%s)
ssh root@geoffcloud k3s kubectl -n boxxy logs -f job/<job-name>
```

Expect the log to end with restic's retention table and `snapshot <id> saved` above it.

## Restore from a backup

`deploy/boxxy/restore-job.yaml` restores the store from a snapshot. It checks each database copy in
the snapshot, then replaces `boxxy.db` and removes its WAL files.

**CAUTION:** A restore replaces the store with the snapshot's. Every task, attempt and fact the
server recorded after the snapshot is lost. Back up first if that state still matters.

1. Stop the server, so nothing writes during the restore:

   ```bash
   ssh root@geoffcloud k3s kubectl -n boxxy scale statefulset/boxxy --replicas=0
   ssh root@geoffcloud k3s kubectl -n boxxy wait --for=delete pod/boxxy-0 --timeout=120s
   ```

   Expect `pod/boxxy-0 condition met`.

2. Restore. Set `args: ["ls"]` in the Job to list the snapshots first, and `SNAPSHOT` to pick one:

   ```bash
   ssh root@geoffcloud k3s kubectl create -f - < deploy/boxxy/restore-job.yaml
   ssh root@geoffcloud k3s kubectl -n boxxy logs -f job/<job-name>
   ```

   Expect restic's `Summary: Restored` line and no error.

3. Start the server, and check that it is up:

   ```bash
   ssh root@geoffcloud k3s kubectl -n boxxy scale statefulset/boxxy --replicas=1
   ssh root@geoffcloud k3s kubectl -n boxxy rollout status statefulset/boxxy --timeout=300s
   ```
