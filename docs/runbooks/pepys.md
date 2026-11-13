# pepys

Runbook for the parts of [pepys](../architecture/workloads/pepys.md) that an operator runs by hand:
the path that carries a session's telemetry to ingest and its token, the API's passkey and OAuth
clients and their public route, and the backup's Garage key and a backup on demand.

## Let sessions send telemetry

A Claude session in an imp sends its OpenTelemetry logs to `https://pepys.imp.internal`, a name that
exists only inside imp's broker. The broker adds the bearer token and an imp identity token, and
forwards the request to the pepys relay on the host's address on Podman's bridge. The relay dials
the ingest Service. The guest holds neither token.

| Where                                           | Holds                                                                    |
| ----------------------------------------------- | ------------------------------------------------------------------------ |
| vault `cloud`, item `pepys-telemetry`           | the bearer token that ingest accepts on its telemetry route              |
| impd, static secret `pepys-telemetry`           | the same token, with `pepys.imp.internal` as its only host, and identity |
| the atc daemon's `pepys-telemetry` auth profile | the secret's name, the host and the session's OpenTelemetry endpoint     |

The path needs the host switch that adds the relay, and the stack config `pepys.impIdentityAudience`
set to `pepys.imp.internal`.

1. Check that impd signs identity tokens. `impz info --json` in imp-host shows `secretIdentity` as
   true under `features`, and `impz identity jwks` prints the document that
   `deploy/pepys/imp-issuers/geoffcloud.json` holds.
2. Add the token to impd. Send it on stdin, and never put it on a command line. The upstream is the
   host's address on Podman's bridge (`podman.bridgeAddress` in the shared constants) and the port
   of the `pepys-ingest-relay` entry in the exposure registry:

   ```sh
   op read op://cloud/pepys-telemetry/credential \
     | ssh root@geoffcloud podman exec -i imp-host impz secret add pepys-telemetry \
         --kind static --hosts pepys.imp.internal --header authorization --scheme bearer \
         --upstream http://10.88.0.1:18083 --identity
   ```

   Read the token on your machine with `op`: imp-host has neither `op` nor a vault credential, so
   the secret travels over SSH's stdin into `impz` in the container. Never put it on the SSH command
   line, because the host's journal records that line.

   Expect `impz secret ls` to show `pepys.imp.internal -> http://10.88.0.1:18083 (identity)`.
   Replacing the token of a secret that exists takes `--replace`, and a change of host, upstream or
   `--identity` takes `--replace --rebind`, which drops the secret's grants.

3. List the secret in the grantable list of the atc daemon's impd token, so the daemon may grant it
   to a session. The command replaces the whole list, and the list is in
   `scripts/atc-cloud-grantable.ts`:

   ```sh
   ssh root@geoffcloud podman exec imp-host impz token set atc-cloud \
     --grantable glm,claude-setup-token,github-imp-agents,linear-imp-agents,op-connect,pepys-telemetry,boxxy,boxxy-github-token \
     < /dev/null
   ```

   `bun scripts/install-atc-gateway-credentials.ts` stops with this command when the token exists
   with another list.

4. Spawn a Claude session through the atc gateway, and check that ingest received its export:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys logs -l app=pepys-ingest --tail=50
   ```

## Rotate the token

1. Put the new token in the item `pepys-telemetry` in `cloud` and in its `cloud-deploy` copy.
2. Run the `impz secret add` command above with `--replace`.
3. [Apply by hand](./workflows.md#apply-by-hand), so Pulumi replaces the ingest Secret. A new secret
   under the same name needs the grantable list set again.

## Turn on the API's public route

**CAUTION:** This adds a public route. Its `Deploy prod` run holds on the tunnel route change until
the owner approves it.

1. In the pull request that pins a `cloud-pepys` image of pepys 0.3.1 or later, add
   `apiHostname: pepys.geoff.cloud` to the `geoff-cloud:pepys` object in `infra/Pulumi.prod.yaml`.
   The program takes 0.3.0, but its compiled API stops at start.
2. Run `bun run preview`. Expect it to add the claim `pepys-auth`, the Access policy and application
   `pepys-api-owner` and `pepys-api-sign-in`, and the record `pepys-api`, and to update the host's
   StatefulSet, the host's network policy and the shared tunnel's configuration. Expect no replace.
3. Merge, and approve the held `Deploy prod` run once its plan matches the preview.
4. Check that the API serves `/mcp` behind its token:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://pepys.geoff.cloud/mcp
   ```

   Expect `401`.

5. Check that the tunnel keeps `/rpc` in:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' https://pepys.geoff.cloud/rpc/
   ```

   Expect `404`.

6. Check that the MCP alias at `/` takes only a POST. cloudflared routes on the path alone, so the
   API refuses the other methods:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' https://pepys.geoff.cloud/
   ```

   Expect `405`.

7. Sign a client in, as [Sign a client in to the API](#sign-a-client-in-to-the-api) says.

## Sign a client in to the API

The API's admin commands run in the API's container, on `mcp-auth.db`, beside the running server.
The commands need the API's public route, as
[Turn on the API's public route](#turn-on-the-apis-public-route) says. Each command below runs
through `pepys-api` in the container `api` of the pod `pepys-host-0`.

1. List the passkeys:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys exec pepys-host-0 -c api -- /usr/local/bin/pepys-api passkeys
   ```

   When it prints `No passkeys`, go on to step 2. Otherwise go to step 3.

2. Print an enrollment token, and type it on `https://pepys.geoff.cloud/enroll` within 15 minutes:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys exec pepys-host-0 -c api -- /usr/local/bin/pepys-api passkeys enroll
   ```

   Cloudflare Access asks for the owner's one-time PIN before the page loads. Expect `passkeys` to
   list the new passkey.

3. Add the client, with a fixed callback port, `<port>`, of your choice:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys exec pepys-host-0 -c api -- /usr/local/bin/pepys-api clients add 'Claude Code' --redirect-uri http://localhost:<port>/callback
   ```

   Expect a client ID, `<client_id>`.

4. In Claude Code, add the MCP server `https://pepys.geoff.cloud/mcp` over HTTP, with `<client_id>`
   in `--client-id` and `<port>` in `--callback-port`. Leave out `--client-secret`, because every
   client is public. Expect the first connection to open the owner's browser on `/oauth2/authorize`.

`grants` lists the live grants, and `grants --revoke=<grant_id>` ends one.
`clients remove <client_id>` removes a client with each grant and token it holds.

## Give the backup its Garage key

Import the backup's key into Garage before the first backup, and again whenever Garage's `meta`
volume is new, such as after a rebuild of Garage's data. Garage creates s2-lite's key itself at each
start, but it never creates the backup's. Without the key, the backup fails with `AccessDenied`.

The vault item `pepys-garage-backup` holds the key in two fields, `access-key-id` and
`secret-access-key`. The prod apply job reads its copy in the `cloud-deploy` vault, so the item
lives in `cloud` and in `cloud-deploy` under the same name. The key can read each bucket that
`pepysWorkloads.backup.buckets` in [`pepys-workloads.ts`](../../infra/shared/pepys-workloads.ts)
lists, and write none.

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
