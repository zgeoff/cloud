# pepys: telemetry from sessions

Let Claude sessions in imps send their OpenTelemetry logs to the ingest of
[pepys](../architecture/workloads/pepys.md), and rotate the token that ingest accepts.
[Let sessions send telemetry](#let-sessions-send-telemetry) follows
[the first deploy of pepys](./pepys.md#deploy-the-first-time), and runs once.
[Rotate the token](#rotate-the-token) replaces the token.

## The path and what holds the token

A Claude session in an [imp](../architecture/host/imp.md) sends its OpenTelemetry logs to
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

The secret tells the broker to add the identity token as well. The auth profile sets the session's
OpenTelemetry endpoint to `https://pepys.imp.internal`. `geoffcloud`'s NixOS configuration defines
the profile and gives it to each Claude session, so no step here creates it.
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
     --grantable glm,claude-setup-token,github-imp-agents,linear-imp-agents,op-connect,pepys-telemetry,boxxy,boxxy-github-token \
     < /dev/null
   ```

   `bun scripts/install-atc-gateway-credentials.ts` checks the same list: it stops and prints this
   command when `atc-cloud` holds another list.

7. Spawn a Claude session through the atc gateway, as
   [the smoke spawn](./atc-gateway-smoke.md#run-the-smoke) does.
8. Read ingest's log:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys logs -l app=pepys-ingest --tail=50
   ```

   Expect `ingest listening on 0.0.0.0:8080`. Ingest never logs an export that it stores, so the log
   shows only that ingest runs. The pepys API's query `telemetry_session_model_requests` returns the
   model requests that pepys stored for one session.

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
