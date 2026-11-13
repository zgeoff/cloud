# pepys: telemetry from sessions

Let Claude sessions in imps send their OpenTelemetry logs to the ingest of
[pepys](../architecture/workloads/pepys.md), and rotate the token that ingest accepts. Use
[Let sessions send telemetry](#let-sessions-send-telemetry) once, after
[the first deploy of pepys](./pepys.md#deploy-the-first-time). Use
[Rotate the token](#rotate-the-token) to replace the token.

## The path and what holds the token

A Claude session in an [imp](../architecture/host/imp.md) sends its OpenTelemetry logs to
`https://pepys.imp.internal`, a name that exists only inside imp's credential broker. The broker
adds the bearer token and an [imp identity token](../architecture/host/imp.md#how-impd-is-reached),
and forwards the request to the pepys relay on the host's address on Podman's bridge. The relay
dials the ingest Service. The guest holds neither token.
[The telemetry path from a session](../architecture/workloads/pepys.md#the-telemetry-path-from-a-session)
explains each hop.

| Where                                           | Holds                                                                    |
| ----------------------------------------------- | ------------------------------------------------------------------------ |
| vault `cloud`, item `pepys-telemetry`           | the bearer token that ingest accepts on its telemetry route              |
| impd, static secret `pepys-telemetry`           | the same token, with `pepys.imp.internal` as its only host, and identity |
| the atc daemon's `pepys-telemetry` auth profile | the secret's name, the host and the session's OpenTelemetry endpoint     |

[The cloud daemon](../architecture/workloads/atc-gateway.md#the-cloud-daemon) covers the atc daemon
and its auth profiles.

## Let sessions send telemetry

Before the steps, check that the path has its parts:

- the host runs a NixOS configuration that holds the relay `pepys-ingest-relay`.
  [Switch the host](./workflows.md#switch-the-host) when it does not;
- the stack config `pepys.impIdentityAudience` is `pepys.imp.internal`, as
  [the first deploy](./pepys.md#deploy-the-first-time) sets it.

1. Check that impd signs identity tokens. In imp-host, `impz info --json` shows `secretIdentity` as
   true under `features`, and `impz identity jwks` prints the document that
   `deploy/pepys/imp-issuers/geoffcloud.json` holds.
2. Add the token to impd. The upstream is the host's address on Podman's bridge and the relay's
   port: `podman.bridgeAddress` in [`constants.json`](../../packages/topology/constants.json), and
   the port of the `pepys-ingest-relay` entry in
   [the exposure registry](../architecture/network/firewalls.md#the-exposure-registry).

   **CAUTION:** Never put the token on the SSH command line, because the host's journal records that
   line. Send the token on stdin, as the command below does.

   ```sh
   op read op://cloud/pepys-telemetry/credential \
     | ssh root@geoffcloud podman exec -i imp-host impz secret add pepys-telemetry \
         --kind static --hosts pepys.imp.internal --header authorization --scheme bearer \
         --upstream http://10.88.0.1:18083 --identity
   ```

   Read the token on your machine with `op`: imp-host has neither `op` nor a vault credential, so
   the secret travels over SSH's stdin into `impz` in the container.

   Expect `impz secret ls` in imp-host to show
   `pepys.imp.internal -> http://10.88.0.1:18083 (identity)`. To replace the token of a secret that
   exists, add `--replace`. To change the host, the upstream or `--identity`, add
   `--replace --rebind`, which drops the secret's grants.

3. List the secret in the grantable list of the atc daemon's impd token, so the daemon may grant the
   secret to a session. The command replaces the whole list, so it names every secret in
   `scripts/atc-cloud-grantable.ts`:

   ```sh
   ssh root@geoffcloud podman exec imp-host impz token set atc-cloud \
     --grantable glm,claude-setup-token,github-imp-agents,linear-imp-agents,op-connect,pepys-telemetry,boxxy,boxxy-github-token \
     < /dev/null
   ```

   `bun scripts/install-atc-gateway-credentials.ts` stops and prints this command when the token
   exists with another list.

4. Spawn a Claude session through the atc gateway, as
   [the smoke spawn](./atc-gateway-smoke.md#run-the-smoke) does.
5. Read ingest's log:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys logs -l app=pepys-ingest --tail=50
   ```

   Expect `ingest listening on 0.0.0.0:8080`. Ingest logs no line for an export that it stores, so
   the log shows only that ingest runs.

## Rotate the token

1. Put the new token in the item `pepys-telemetry` in the vault `cloud` and in its copy in the vault
   `cloud-deploy`, which the prod apply job reads.
2. Run the `impz secret add` command of [Let sessions send telemetry](#let-sessions-send-telemetry)
   with `--replace` added.
3. [Apply by hand](./workflows.md#apply-by-hand), so Pulumi replaces the ingest Secret.

A new secret under the same name needs the grantable list set again, as step 3 of
[Let sessions send telemetry](#let-sessions-send-telemetry) does.
