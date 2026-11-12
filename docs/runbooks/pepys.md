# pepys

Runbook for the parts of [pepys](../architecture/workloads/pepys.md) that an operator sets up by
hand. For now that is the path that carries a session's telemetry to ingest.

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
     | impz secret add pepys-telemetry --kind static --hosts pepys.imp.internal \
         --header authorization --scheme bearer --upstream http://10.88.0.1:18082 --identity
   ```

   Expect `impz secret ls` to show `pepys.imp.internal -> http://10.88.0.1:18082 (identity)`.
   Replacing the token of a secret that exists takes `--replace`, and a change of host, upstream or
   `--identity` takes `--replace --rebind`, which drops the secret's grants.

3. List the secret in the grantable list of the atc daemon's impd token, so the daemon may grant it
   to a session. The command replaces the whole list, and the list is in
   `scripts/atc-cloud-grantable.ts`:

   ```sh
   ssh root@geoffcloud podman exec imp-host impz token set atc-cloud \
     --grantable glm,claude-setup-token,github-imp-agents,linear-imp-agents,op-connect,pepys-telemetry,boxxy \
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
