# The boxxy server

The boxxy server runs as the `boxxy` StatefulSet in k3s, on a retained local-path volume that holds
its SQLite store. The `boxxy-backup` CronJob backs the store up every night with restic to a `boxxy`
repository in R2. Setting the stack config `boxxy` approves the deploy, and leaving it unset keeps
the server out of the cluster. [The workload doc](../architecture/workloads/boxxy.md) covers the
listeners, the configuration and the caller proof.

## What holds what

| Item in the `cloud` vault | Holds                                                     | Read by               |
| ------------------------- | --------------------------------------------------------- | --------------------- |
| `boxxy-worker-token`      | the worker token, which the broker adds to worker calls   | Pulumi, impd's broker |
| `boxxy-atc-token`         | the bearer token the server sends to the atc gateway      | Pulumi                |
| `boxxy-restic`            | the restic repository's password                          | Pulumi, the backup    |
| `r2-boxxy-backup`         | the R2 key, endpoint and bucket of the restic repository  | Pulumi, the backup    |
| `boxxy-pepys-signing`     | the key the server signs its facts with                   | Pulumi, pepys ingest  |
| `boxxy-github-token`      | the read-only clone token                                 | the atc daemon, impd  |
| `boxxy-github-app`        | the boxxy App's keys, for every GitHub call of the server | Pulumi                |

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

   For a private repo, add `"credentialRef": { "name": "ATC_GIT_CLONE_TOKEN" }` to its git source.
   It names the atc daemon's environment variable that holds a read-only clone token, never the
   token itself, and it needs a server that takes `credentialRef`.

   ```bash
   cd infra
   op run --env-file=../.env -- pulumi config set --stack prod --secret boxxySpawnRepos < <file of JSON>
   ```

   Check that the diff of `infra/Pulumi.prod.yaml` adds only a `secure:` value under
   `geoff-cloud:boxxySpawnRepos`. Each imp is a fresh machine, so each repo is a git source. The atc
   daemon clones it, with the token that its `credentialRef` names for a private repo, so the URL
   carries no credential, and the server skips the trusted-folder check for a git source.

   The image must hold a server that calls atc over MCP. Leave out the `BOXXY_RESTIC_*` and
   `BOXXY_R2_*` lines until both of their items exist: the backup takes all five variables or none,
   and one alone fails the preview.

   Run `bun run preview` and check that it adds the `boxxy` namespace, its Secrets, both ConfigMaps,
   both Services, both NetworkPolicies, the StatefulSet, and the backup Secret and CronJob, and
   changes nothing else. Without the `BOXXY_RESTIC_*` and `BOXXY_R2_*` variables, the server deploys
   with no backup.

4. Merge the PR. `Deploy prod` applies it, since every step is a create.
5. Check that the pod is up and its listeners started:

   ```bash
   ssh root@geoffcloud k3s kubectl -n boxxy rollout status statefulset/boxxy --timeout=300s
   ssh root@geoffcloud k3s kubectl -n boxxy logs boxxy-0 | grep 'boxxy server listening'
   ```

   Expect `statefulset rolling update complete`, then one line with `"ownerPort":8090`,
   `"workerPort":8091` and `"publicPort":null`, or `"publicPort":8092` with the public door.

## Reach the owner listener

The owner listener has no route, so forward its port through SSH and leave the command running:

```bash
ssh -L 8090:localhost:8090 root@geoffcloud k3s kubectl -n boxxy port-forward svc/boxxy 8090
```

Then set `BOXXY_URL=http://localhost:8090` for the boxxy CLI.

## Turn on the public door

The public door serves the owner's MCP tools at `https://boxxy.geoff.cloud/mcp`, behind the server's
own OAuth, through a tunnel of its own
([the workload doc](../architecture/workloads/boxxy.md#the-public-door)). It needs an image with
`@boxxy/server` 0.2.1 or later, because an older server refuses a configuration with a `publicDoor`
section and does not start.

1. In a PR, add the section to the `boxxy` object in `infra/Pulumi.prod.yaml`:

   ```yaml
   publicDoor:
     publicURL: https://boxxy.geoff.cloud
     trustForwardedFrom:
       - 127.0.0.1
   ```

   Run `bun run preview`. Expect it to create the `boxxy` tunnel, its configuration and its DNS
   record, the `boxxy-door-owner` Access policy and the `boxxy-door-sign-in` Access application, and
   the Secret `boxxy-door-tunnel-token`. Expect it to replace the ConfigMap `boxxy-config` and
   update the StatefulSet, and to change nothing else.

2. Merge it. The guard of `Deploy prod` holds the plan, because it creates a tunnel's routes, a DNS
   record and an Access application. Read the held plan and dispatch it, as
   [the prod apply runbook](./prod-apply.md#answer-a-held-run) says.
3. Check the route from any machine:

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' https://boxxy.geoff.cloud/.well-known/oauth-protected-resource
   curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://boxxy.geoff.cloud/mcp
   curl -sS -o /dev/null -w '%{http_code}\n' https://boxxy.geoff.cloud/rpc
   ```

   Expect `200`, then `401`, then `404`.

4. [Reach the owner listener](#reach-the-owner-listener), and enroll a passkey:

   ```bash
   BOXXY_URL=http://localhost:8090 boxxy auth enroll
   ```

   Expect `Enrollment link: https://boxxy.geoff.cloud/enroll?token=<token>`. Open the link in your
   browser, sign in to Access with the one-time PIN, and save the passkey before the link expires.

5. Add each MCP client with its redirect URI:

   ```bash
   BOXXY_URL=http://localhost:8090 boxxy auth clients add <client_name> --redirect-uri <redirect_uri>
   ```

   `<client_name>` is the name the consent page shows, and `<redirect_uri>` is the callback URL the
   client's OAuth settings give. Expect `Added <client_name>. Its client ID is <client_id>`, and
   give the client that ID with `https://boxxy.geoff.cloud/mcp` as its server URL.

`boxxy auth clients` and `boxxy auth grants` list and remove clients and grants. The backup copies
the door's auth database with the store, and a restore puts both back.

## Let sessions reach the server

A worker session in an imp reaches the worker listener at `https://boxxy.imp.internal`, the broker
host in the shared constants. The atc daemon's `boxxy` agent loads the boxxy hook plug-in and its
`boxxy` auth profile sets `BOXXY_URL` in the session. The broker adds the worker token and an imp
identity token, and forwards the request to the boxxy relay on the host's address on Podman's
bridge, which dials the `boxxy-worker` Service. These steps follow the host switch that adds the
relay and the daemon's new config.

1. Add the worker token to impd. Send it on stdin, and never put it on a command line. The upstream
   is the host's address on Podman's bridge (`podman.bridgeAddress` in the shared constants) and the
   port of the `boxxy-worker-relay` entry in the exposure registry:

   ```sh
   op read op://cloud/boxxy-worker-token/credential \
     | ssh root@geoffcloud podman exec -i imp-host impz secret add boxxy \
         --kind static --hosts boxxy.imp.internal --header authorization --scheme bearer \
         --upstream http://10.88.0.1:18084 --identity
   ```

   Read the token on your machine with `op`: imp-host has neither `op` nor a vault credential, so
   the secret travels over SSH's stdin into `impz` in the container. Never put it on the SSH command
   line, because the host's journal records that line. Expect `impz secret ls` to show
   `boxxy.imp.internal -> http://10.88.0.1:18084 (identity)`. Impd signs identity tokens only with
   `IMP_IDENTITY_ISSUER` set, which the host's config sets to `geoffcloud`. Replacing the token of a
   secret that exists takes `--replace`, and a change of host, upstream or `--identity` takes
   `--replace --rebind`, which drops the secret's grants.

2. List `boxxy` and `pepys-telemetry` in the grantable list of the atc daemon's impd token, so the
   daemon may grant them to a session. The command replaces the whole list, which
   `scripts/atc-cloud-grantable.ts` holds:

   ```sh
   ssh root@geoffcloud podman exec imp-host impz token set atc-cloud \
     --grantable glm,claude-setup-token,github-imp-agents,linear-imp-agents,op-connect,pepys-telemetry,boxxy,boxxy-github-token \
     < /dev/null
   ```

   `bun scripts/install-atc-gateway-credentials.ts` stops with this command when the token exists
   with another list.

3. Restart the atc daemon if the switch did not, so it reads the new `boxxy` agent and profiles. A
   switch that changes the daemon's config restarts it.

[The pepys telemetry runbook](./pepys-telemetry.md#let-sessions-send-telemetry) covers the telemetry
secret, which every Claude session uses.

## The service token at the atc gateway

The boxxy server signs in to the atc gateway with a service token, which the gateway reads from a
file at start (`atc-gateway --service-token-file`, atc 7.14.0 and later). Pulumi builds the file
from `BOXXY_ATC_TOKEN` and the gateway's public URL, puts it in a Secret with no fixed name, and
passes the flag. The server calls atc as the principal `service:boxxy`, which the daemon's
`principals` lists with the target `geoffcloud`.

- Mint the token as `atcs_` and 64 hex characters, and put it in the item `boxxy-atc-token` in
  `cloud` and in its `cloud-deploy` copy:

  ```bash
  printf 'atcs_%s' "$(openssl rand -hex 32)"
  ```

- While `images/atc-gateway/versions.env` pins an atc release older than 7.14.0, Pulumi leaves the
  file, the mount and the flag out and prints one warning when it loads the inputs. The token then
  need not have that shape. The stack's `atcGateway.image` gates it the same way, because the image
  that the stack deploys is the one that must know the flag, and the pin only builds the next one.
  Once the pin and `atcGateway.image` are both 7.14.0 or later, the next apply adds the Secret, an
  init container and the flag.
- The gateway refuses a token file that another user owns or that its group or others can open, and
  Kubernetes gives a Secret volume's files to root. So an init container, running as the gateway's
  user, copies the file to a memory volume with mode 0600, and the gateway mounts that volume
  read-only.

## The daemon's clone token

The atc daemon on the host clones a session's git workspace itself, before the session exists, so
the session's GitHub broker profile does not apply. For a private repo it reads the clone token from
the environment variable that the spawn's `source.credentialRef.name` names. The boxxy server sends
`ATC_GIT_CLONE_TOKEN`, and atc runs `git ls-remote` on the host with the same token to resolve the
ref. Without the variable, a spawn of a private repo fails with `clone_failed` and git's
`could not read Username` message.

- The token is a read-only fine-grained GitHub token (Contents and Pull requests read on the boxxy
  repos) in the item `boxxy-github-token`, field `credential`, in the `cloud` vault.
- The host keeps it in `/var/lib/atc-daemon-secrets/git-clone-token`, mode 0400, owned by root. The
  NixOS option `services.atc-daemon.environmentCredentials` passes the file in as a systemd
  credential and sets the variable in the daemon's process only. atc withholds the variable from
  every harness it starts. A check unit names a missing or empty file before the daemon starts.
- Install or refresh the file with the repo name that the token must read, which stays out of the
  repo:

  ```bash
  ATC_GIT_CLONE_CHECK_REPO=<owner>/<repo> bun scripts/install-atc-git-clone-token.ts
  ```

  The script sends the token on SSH's stdin. It skips when the file's token already reads that repo,
  and otherwise writes it and checks it again.

- A new token reaches the daemon only after `systemctl restart atc-daemon`.

## Add a trust document

1. Write the impd's document, as `impz identity jwks` prints it on that impd's host, to
   `deploy/boxxy/issuers/<issuer>.json`.
2. Merge it in a PR. The preview shows the new `boxxy-issuers` ConfigMap, a new `boxxy-config`
   ConfigMap that gains the `trustedIssuers` section, and an update of the StatefulSet. The pod
   rolls, and session and hook calls from that impd's imps pass the caller proof.

## Send facts to pepys and read pull requests

The server sends its facts to pepys and reads its two reports there once stack config `boxxy` has a
`pepys` section, and it links and watches pull requests once it has a `github` section. Each section
needs its token in `.env`, and the program stops with the name of the variable when it is unset.

1. For pepys, check that stack config `pepys` is set and that pepys ingest and the pepys API admit
   the boxxy server's pod, as [the pepys workload doc](../architecture/workloads/pepys.md) says. Add
   the line that reads the item pepys ingest reads too:

   ```bash
   BOXXY_PEPYS_SIGNING_SECRET=op://cloud/boxxy-pepys-signing/credential
   ```

2. For GitHub, install the boxxy App on every repo in `boxxySpawnRepos`: the server makes every
   GitHub call as the App. Store the App's keys as `boxxy-github-app` in `cloud` and `cloud-deploy`,
   with the fields `client-id`, `private-key` and `installation-id`. Add the lines:

   ```bash
   BOXXY_GITHUB_APP_CLIENT_ID=op://cloud/boxxy-github-app/client-id
   BOXXY_GITHUB_APP_PRIVATE_KEY=op://cloud/boxxy-github-app/private-key
   BOXXY_GITHUB_APP_INSTALLATION_ID=op://cloud/boxxy-github-app/installation-id
   ```

   The preview fails while `github` is set and any of the three is unset.

3. Add the sections to the `boxxy` object in `infra/Pulumi.prod.yaml`:

   ```yaml
   pepys:
     environment: production
   github:
     baseUrl: https://api.github.com
   ```

   `environment` names the deploy environment whose deploys the stage times count. The cluster sets
   the pepys addresses itself, from pepys's Services and the boxxy route in
   `deploy/pepys/ingest-routes.json`.

4. Run `bun run preview` and check that it replaces the Secret `boxxy-tokens` and the ConfigMap
   `boxxy-config`, updates the StatefulSet, and changes nothing else.

## Turn on the review gate

The review phase runs noslop in a session on the `boxxy-review` agent, and the server checks and
posts the result as the noslop App. Without the App's keys, the server rejects every review
close-out, and each item holds at review after two sessions.

1. Copy the item `noslop-github-app` into `cloud` and `cloud-deploy`, with the fields `app-id`,
   `private-key` and `installation-id`. Install the noslop App on every repo in `boxxySpawnRepos`.
2. Give impd the read-only clone token as the secret `boxxy-github-token`, of kind `github`, from
   the item of the same name. Send it as step 1 of
   [Let sessions reach the server](#let-sessions-reach-the-server) sends `boxxy`: `op read` on your
   machine, piped over SSH's stdin into `impz secret add boxxy-github-token --kind github` in
   imp-host. Then set the daemon token's grantable list from `scripts/atc-cloud-grantable.ts`, which
   names `boxxy-github-token`, with the `impz token set atc-cloud` command of that section.
3. Switch the host, so the atc daemon offers the `boxxy-review` agent and its `github-review`
   profile.
4. Add the lines to `.env`:

   ```bash
   NOSLOP_GITHUB_APP_ID=op://cloud/noslop-github-app/app-id
   NOSLOP_GITHUB_APP_PRIVATE_KEY=op://cloud/noslop-github-app/private-key
   NOSLOP_GITHUB_APP_INSTALLATION_ID=op://cloud/noslop-github-app/installation-id
   ```

5. In the same PR as an image pin of `@boxxy/server` 0.2.4 or later, add
   `reviewAgents: [boxxy-review]` to `spawn` in the `boxxy` object of `infra/Pulumi.prod.yaml`. An
   older server refuses the field.
6. Run `bun run preview`. Expect it to replace the Secret `boxxy-tokens` and the ConfigMap
   `boxxy-config`, and to update the StatefulSet.
7. Merge it. After the deploy, a review round leaves noslop's check run at the pull request's head,
   posted by the App.

## Upgrade the server

1. Merge the change: a new `@boxxy/server` version in `package.json` and `bun.lock`, or a change to
   `deploy/boxxy/`. The `boxxy image` workflow publishes the new commit's image.
2. In a PR, set `boxxy.image` in `infra/Pulumi.prod.yaml` to the new tag and digest.
3. Merge it. `Deploy prod` rolls `boxxy-0`; the server is down for the restart.

## Rotate a token

1. Mint a new value with `openssl rand -hex 32` (for the atc token, `atcs_` and that value, as
   [the service token](#the-service-token-at-the-atc-gateway) says), and put it in the item in
   `cloud` and in its `cloud-deploy` copy. For the worker token, also replace impd's `boxxy` secret.
2. [Apply by hand](./workflows.md#apply-by-hand) from `main`. The `Deploy prod` job applies only a
   new commit, so it never runs for a change in 1Password alone. Both drift checks and the preview
   show one change: Pulumi replaces the Secret `boxxy-tokens`. Expect nothing else.
3. The new Secret rolls `boxxy-0`, and the old token stops working once the new pod is ready. A new
   atc token also replaces the gateway's `atc-gateway-service-tokens` Secret, which rolls the
   gateway.

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
