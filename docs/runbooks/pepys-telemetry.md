# pepys: telemetry from sessions

Let Claude and Codex sessions in imps send their OpenTelemetry logs to the ingest of
[pepys](../architecture/workloads/pepys.md), and rotate the token that ingest accepts.
[Let sessions send telemetry](#let-sessions-send-telemetry) follows
[the first deploy of pepys](./pepys.md#deploy-the-first-time), and runs once.
[Rotate the token](#rotate-the-token) replaces the token. [Add a forwarder](#add-a-forwarder) lets a
machine outside impz, such as the owner's PC, send its logs through
[the forwarders' tailnet route](../architecture/workloads/pepys.md#the-forwarders-tailnet-route),
and [Rotate or remove a forwarder's key](#rotate-or-remove-a-forwarders-key) changes what ingest
trusts.

## The path and what holds the token

A Claude or Codex session in an [imp](../architecture/host/imp.md) sends its OpenTelemetry logs to
`https://pepys.imp.internal`, a name that exists only inside impd's credential broker. impd runs in
the Podman container `imp-host` on the machine `geoffcloud`. The broker adds the bearer token and an
[imp identity token](../architecture/host/imp.md#how-impd-is-reached) to each request, and forwards
the request to the pepys relay, which listens on `geoffcloud`'s address on Podman's bridge. The
relay dials the ingest Service. The session holds neither token.
[The telemetry path from a session](../architecture/workloads/pepys.md#the-telemetry-path-from-a-session)
explains each hop.

| Where                                           | Holds                                                                           |
| ----------------------------------------------- | ------------------------------------------------------------------------------- |
| vault `cloud`, item `pepys-telemetry`           | the bearer token that ingest accepts on its telemetry route                     |
| impd, static secret `pepys-telemetry`           | the same token, which the broker adds only to requests for `pepys.imp.internal` |
| the atc daemon's `pepys-telemetry` auth profile | the secret's name                                                               |

The secret tells the broker to add the identity token as well. The auth profile holds
`telemetry.logs`, so atc points the log export of each session that selects the profile at
`https://pepys.imp.internal`: Claude Code through four OpenTelemetry variables, and Codex through
the `[otel]` section of its `config.toml`. `geoffcloud`'s NixOS configuration defines the profile
and gives it to each agent, so no step here creates it. No agent entry or profile in that
configuration sets `CLAUDE_CODE_ENABLE_TELEMETRY`, `OTEL_LOGS_EXPORTER`,
`OTEL_EXPORTER_OTLP_PROTOCOL` or `OTEL_EXPORTER_OTLP_ENDPOINT`, because atc refuses an entry that
sets one beside the profile.
[The cloud daemon](../architecture/workloads/atc-gateway.md#the-cloud-daemon) covers the atc daemon
and its auth profiles.

## Let sessions send telemetry

1. Check that `geoffcloud` runs the relay:

   ```sh
   ssh root@geoffcloud systemctl is-active pepys-ingest-relay.socket
   ```

   Expect `active`. When the unit does not exist, [switch the host](./workflows.md#switch-the-host)
   to a commit of `main` first.

2. Check that `impIdentityAudience` in the `geoff-cloud:pepys` object of `infra/Pulumi.prod.yaml` is
   `pepys.imp.internal`, as [the first deploy](./pepys.md#deploy-the-first-time) sets it.
3. Check that impd signs identity tokens. In `imp-host`, `impz info --json` shows `secretIdentity`
   as true under `features`, and `impz identity jwks` prints the document that
   `deploy/pepys/imp-issuers/geoffcloud.json` holds.
4. Check the command's `--upstream` value before you run the command. Its address is
   `podman.bridgeAddress` in [`constants.json`](../../packages/topology/constants.json), and its
   port is the port of the `pepys-ingest-relay` entry in
   [the exposure registry](../architecture/network/firewalls.md#the-exposure-registry). When a value
   differs, use the file's value.
5. Add the bearer token to impd.

   **CAUTION:** Never put the bearer token on the SSH command line, because `geoffcloud`'s journal
   records that line. Send the token on stdin, as the command below does.

   ```sh
   op read op://cloud/pepys-telemetry/credential \
     | ssh root@geoffcloud podman exec -i imp-host impz secret add pepys-telemetry \
         --kind static --hosts pepys.imp.internal --header authorization --scheme bearer \
         --upstream http://10.88.0.1:18083 --identity
   ```

   Read the token on your machine with `op`: `imp-host` has neither `op` nor a vault credential, so
   the token travels over SSH's stdin into `impz` in the container.

   Expect `impz secret ls` in `imp-host` to show
   `pepys.imp.internal -> http://10.88.0.1:18083 (identity)`. To replace the token of a secret that
   exists, add `--replace`. To change `--hosts`, `--upstream` or `--identity` of a secret that
   exists, add `--replace --rebind`, which drops each grant of the secret to an imp.

6. List the secret in the grantable list of the atc daemon's impd token, `atc-cloud`, so the daemon
   can grant the secret to a session.

   **CAUTION:** The command replaces the whole list, so a name it leaves out is a secret the daemon
   can no longer grant. Compare the command's list with `scripts/atc-cloud-grantable.ts` before you
   run the command, and use the script's list when the two differ.

   ```sh
   ssh root@geoffcloud podman exec imp-host impz token set atc-cloud \
     --grantable glm,claude-setup-token,github-imp-agents,linear-imp-agents,op-connect,pepys-telemetry,boxxy,boxxy-github-token,codex-chatgpt \
     < /dev/null
   ```

   `bun scripts/install-atc-gateway-credentials.ts` checks the same list: it stops and prints this
   command when `atc-cloud` holds another list.

7. Spawn a Claude session through the atc gateway, as
   [the smoke spawn](./atc-gateway-smoke.md#run-the-smoke) does. To check Codex, spawn a session of
   the `codex` agent the same way.
8. Read ingest's log:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys logs -l app=pepys-ingest --tail=50
   ```

   Expect `ingest listening on 0.0.0.0:8080`. Ingest logs no line for an export that it refuses, and
   none for an export whose every record it keeps. It logs one warning,
   `the source telemetry dropped log records`, for each export that it accepts and drops a record
   from.

9. Wait until the session has answered the `prompt` that the spawn of step 7 gave it:
   `atc_sessions_list` then shows the session's `state` as `done`. Then read the model requests that
   pepys stored for the session, from a device on the tailnet:

   ```sh
   curl -s -X POST -H 'content-type: application/json' \
     -d '{"json":{"session":"telemetry:session:<session_id>","issuer":"geoffcloud","subject":"<imp_id>"}}' \
     https://pepys-api.geoff.cloud/rpc/telemetry_session_model_requests
   ```

   - `<session_id>` is the atc session's ID, which the spawn of step 7 returned as `id`.
   - `<imp_id>` is the ID of the imp that runs the session: `host.id` of the session in the answer
     of `atc_sessions_list`, or the `id` beside the imp's name in `impz ls --json` in `imp-host`.
     atc names the imp `harness-` plus the first 20 hex digits of the session ID.
   - `geoffcloud` is the issuer name of the imp host, the name of its file in
     `deploy/pepys/imp-issuers/`.

   The command uses [the API's tailnet route](./pepys-api.md#turn-on-the-apis-tailnet-route). While
   that route is off,
   [reach `/rpc` through a port-forward](./pepys-api.md#reach-rpc-while-the-tailnet-route-is-off).

   Expect one object for each model request, oldest first, in this form:

   ```json
   {
     "json": [
       {
         "id": "telemetry:model_request:claude_code.api_request:<request_id>",
         "product": "claude_code",
         "model": "<model>",
         "input_tokens": 2,
         "cache_read_tokens": 12589,
         "cache_creation_tokens": 17627,
         "output_tokens": 160,
         "cost_usd": 0.1467418,
         "at": "2026-11-18T09:28:28.436Z"
       }
     ]
   }
   ```

   A Codex session's rows have the `product` `codex` and a null `cost_usd`.

### When the query returns an empty list

The API answers `{"json":[]}` when no stored row matches all three values, so the session may still
have sent telemetry. Check these, in order, and run the query again after each fix:

1. Check the `session` value. It must be the whole entity ID, `telemetry:session:<session_id>`. The
   API answers `{"json":[]}` for the bare session ID.
2. Check the `subject` value. It must be the imp's `id`. The API answers `{"json":[]}` for the imp's
   name.
3. Check that `atc_sessions_list` shows the session's `state` as `done`. A session that answered no
   prompt made no model request.
4. Read ingest's log with the command of step 8 of
   [Let sessions send telemetry](#let-sessions-send-telemetry), for the warning
   `the source telemetry dropped log records`. Ingest writes it once for each export that it accepts
   and drops one record or more from, and also when it drops every record. The warning's `detail`
   counts the dropped records by reason, such as `unknown-product`. Ingest never stores a dropped
   record, so the query never returns its model request.
5. Read the secret's row:

   ```sh
   ssh root@geoffcloud podman exec imp-host impz secret ls < /dev/null
   ```

   Expect the row `pepys-telemetry` to show
   `pepys.imp.internal -> http://10.88.0.1:18083 (identity)`, and to end with the names of the imps
   that hold a grant of the secret, the session's imp among them.
   - When the session's imp is missing, the atc daemon gave the session no grant. Do step 6 of
     [Let sessions send telemetry](#let-sessions-send-telemetry), then spawn a new session.
   - When `(identity)` is missing, the broker adds no identity token, and ingest answers 401 to each
     export and logs nothing. Add the secret again as step 5 of
     [Let sessions send telemetry](#let-sessions-send-telemetry) says for a change to `--identity`.
     That step drops each imp's grant of the secret, so set the grantable list again as step 6 does,
     then spawn a new session.

6. When the API still answers `{"json":[]}`, [rotate the token](#rotate-the-token). Ingest also
   answers 401 to a wrong bearer token, and no command compares impd's copy of the token with the
   copy in ingest's Secret.

## Rotate the token

1. Put the new token in the item `pepys-telemetry` in the vault `cloud` and in its copy in the vault
   `cloud-deploy`, which [the prod apply job](./prod-apply.md) reads.
2. Run the `impz secret add` command of [Let sessions send telemetry](#let-sessions-send-telemetry)
   with `--replace` added. Expect `impz secret ls` in `imp-host` to show the same line as before.
3. [Apply by hand](./workflows.md#apply-by-hand), so Pulumi replaces the ingest Secret.
4. Check that ingest rolled:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys rollout status deployment/pepys-ingest --timeout=300s
   ```

   Expect `deployment "pepys-ingest" successfully rolled out`.

A secret that you remove and add again under the same name needs the grantable list set again, as
step 6 of [Let sessions send telemetry](#let-sessions-send-telemetry) does.

## Add a forwarder

Ingest trusts a forwarder by its trust document, one JSON file in `deploy/pepys/forwarder-issuers/`
named after the forwarder's issuer. These steps use the issuer `home-wsl`.

**CAUTION:** Each process that runs as the machine's user can read the forwarder's key, and each
holder of the key can write telemetry log records under the issuer from any tailnet device. Add a
document only for a machine whose user the owner trusts with that.

1. On the machine, install the forwarder and print its trust document:

   ```sh
   pepys-telemetry-forwarder install --issuer home-wsl --audience pepys.forwarder.internal \
     --ingest-url https://pepys-forwarder.geoff.cloud > home-wsl.json
   ```

   The audience must equal `audience` in the `forwarder` object of `geoff-cloud:pepys` in
   `infra/Pulumi.prod.yaml`.

2. Open a pull request that adds the file as `deploy/pepys/forwarder-issuers/home-wsl.json`.
3. Run the check of the folder:

   ```sh
   bun test infra/cluster/collect-pepys-forwarder-trust-failures.test.ts
   ```

   Expect every test to pass. The check fails for a file that ingest's loader refuses, a file not
   named `<issuer>.json`, and an issuer name or a key that `deploy/pepys/imp-issuers/` holds. Ingest
   would exit at start for each of these, except the file name.

4. Merge the pull request. The `Deploy prod` run of the merge replaces the ConfigMap
   `pepys-forwarder-issuers` and rolls ingest, with no hold.
5. Check that ingest rolled:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys rollout status deployment/pepys-ingest --timeout=300s
   ```

   Expect `deployment "pepys-ingest" successfully rolled out`.

6. On the machine, start the forwarder:

   ```sh
   systemctl --user enable --now pepys-telemetry-forwarder.service
   ```

7. [Check the forwarders' route](#check-the-forwarders-route).

### Check the forwarders' route

Run each command on a device on the tailnet.

1. Check that the route refuses a request with no identity token:

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://pepys-forwarder.geoff.cloud/forwarded/v1/logs
   ```

   Expect `401`. Only ingest gives this answer. Traefik answers `404` while ingest runs a pepys
   release older than 0.4.5, which has no sender route.

2. Check that the name keeps ingest's other routes closed:

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://pepys-forwarder.geoff.cloud/v1/logs
   ```

   Expect `404`, Traefik's answer.

3. Check that ingest refuses none of the forwarder's records. Read ingest's log for a warning that
   names the sender route:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys logs deployment/pepys-ingest --since=10m | grep forwarded
   ```

   Expect no line. On the machine, `journalctl --user -u pepys-telemetry-forwarder` shows each send
   that ingest refused, with its status.

## Rotate or remove a forwarder's key

Ingest refuses a token from a key that no document in the folder holds, from its next start. The
records that the old key wrote stay in the log, under the issuer.

1. To rotate the key, move the forwarder's identity folder away on the machine. Then run the
   `install` command of [Add a forwarder](#add-a-forwarder) again, with the same issuer. It makes a
   new key and prints the new trust document.
2. Open a pull request that replaces `deploy/pepys/forwarder-issuers/<issuer>.json` with the new
   document. To remove the forwarder, delete the file.
3. Follow steps 3 to 5 of [Add a forwarder](#add-a-forwarder).
4. On the machine, restart the forwarder with
   `systemctl --user restart pepys-telemetry-forwarder.service`. Skip this step when you removed the
   forwarder.
