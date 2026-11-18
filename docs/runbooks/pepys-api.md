# pepys: the API's routes and its clients

The API of [pepys](../architecture/workloads/pepys.md) has two routes. The public route carries MCP
and the sign-in pages to clients on the internet. The tailnet route carries the typed queries under
`/rpc` to devices on the tailnet. Use the procedure for your task:

- [Turn on the API's public route](#turn-on-the-apis-public-route) adds the public route to a
  deployment that has none.
- [Sign a client in to the API](#sign-a-client-in-to-the-api) enrolls the owner's passkey and adds
  an MCP client.
- [Add a service client](#add-a-service-client) lets a client with no person present sign in with a
  secret.
- [End a client's access](#end-a-clients-access) removes a client.
- [Turn on the API's tailnet route](#turn-on-the-apis-tailnet-route) adds the tailnet route and
  checks it.
- [Turn off the API's tailnet route](#turn-off-the-apis-tailnet-route) removes the tailnet route.
- [Reach `/rpc` while the tailnet route is off](#reach-rpc-while-the-tailnet-route-is-off) gives a
  port-forward to the API.

[The API's public route](../architecture/workloads/pepys.md#the-apis-public-route) and
[The API's tailnet route](../architecture/workloads/pepys.md#the-apis-tailnet-route) explain what
each route is made of.
[The pepys API's route boundary](../architecture/network/public-ingress.md#the-pepys-apis-route-boundary)
lists what each path of the public route checks.

## Turn on the API's public route

The route is on while [stack config](./workflows.md#change-stack-config) `pepys.apiHostname` names a
host: the key `apiHostname` in the `geoff-cloud:pepys` object of `infra/Pulumi.prod.yaml`.

**CAUTION:** These steps add a public route. The `Deploy prod` run of the change holds at the tunnel
route change, and step 4 answers the held run. Get the owner's approval before you answer it, as
[the prod apply job](./prod-apply.md) describes.

**CAUTION:** Add the key only beside a `cloud-pepys` image of pepys 0.3.1 or later. The Pulumi
program accepts an image of pepys 0.3.0, but the API in that image stops when it starts.

1. Open a pull request that adds `apiHostname: pepys.geoff.cloud` to the `geoff-cloud:pepys` object
   in `infra/Pulumi.prod.yaml`. When the object's `image` is older than pepys 0.3.1, pin a later
   image in the same pull request, as [Bump the pepys release](./pepys.md#bump-the-pepys-release)
   says.
2. Run `bun run preview` from the repo root, as [First preview](./development.md#first-preview) sets
   up. Expect no replace. Expect the preview to add these:
   - the volume claim `pepys-auth`;
   - the Cloudflare Access policy `pepys-api-owner`;
   - the Access application `pepys-api-sign-in`;
   - the DNS record `pepys-api`.

   Expect the preview to update the StatefulSet `pepys-host`, that pod's network policy and the
   configuration of
   [the shared tunnel](../architecture/network/public-ingress.md#the-shared-tunnel).

3. Merge the pull request.
4. Answer the held `Deploy prod` run once its plan matches the preview, as
   [Answer a held run](./prod-apply.md#answer-a-held-run) says.
5. Check that the API serves `/mcp` behind its token:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://pepys.geoff.cloud/mcp
   ```

   Expect `401`.

6. Check that the tunnel keeps `/rpc` off the public route:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' https://pepys.geoff.cloud/rpc/
   ```

   Expect `404`.

7. Check that `/`, which the API serves as a second path for `/mcp`, takes only a POST. The tunnel's
   cloudflared routes a request by its path alone, whatever its method, so the API is what refuses a
   GET:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' https://pepys.geoff.cloud/
   ```

   Expect `405`.

8. [Sign a client in to the API](#sign-a-client-in-to-the-api).

## Sign a client in to the API

[Turn on the API's public route](#turn-on-the-apis-public-route) first, because the admin commands
need the route. Each command below runs `pepys-api` in the container `api` of the pod
`pepys-host-0`, beside the running server. It works on `mcp-auth.db`, the database of the API's
OAuth server.

1. List the passkeys:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys exec pepys-host-0 -c api -- /usr/local/bin/pepys-api passkeys
   ```

   When it prints `No passkeys`, go on to step 2. Otherwise go to step 4.

2. Print an enrollment token:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys exec pepys-host-0 -c api -- /usr/local/bin/pepys-api passkeys enroll
   ```

3. Within 15 minutes, open `https://pepys.geoff.cloud/enroll` in the owner's browser. Cloudflare
   Access asks for the owner's one-time PIN before the page loads. Type the token on the page, which
   enrolls a passkey. Expect the command of step 1 to list the new passkey.
4. Add the client, with a fixed callback port, `<port>`, of your choice:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys exec pepys-host-0 -c api -- /usr/local/bin/pepys-api clients add 'Claude Code' --redirect-uri http://localhost:<port>/callback
   ```

   Expect a client ID, `<client_id>`.

5. In Claude Code, add the MCP server over HTTP:

   ```sh
   claude mcp add --transport http --client-id <client_id> --callback-port <port> pepys https://pepys.geoff.cloud/mcp
   ```

   Leave out `--client-secret`: the OAuth server gives no client a secret. Expect the first
   connection to open the owner's browser on `/oauth2/authorize`.

## Add a service client

A service client signs in at `/mcp` with the read scope.
[The API's public route](../architecture/workloads/pepys.md#the-apis-public-route) explains the
service-token file that holds its digest. The route must be on, and the image must hold pepys 0.4.3
or later.

1. Keep the client's secret in the 1Password vault of the client's owner, never in this repo. Take
   the sha256 digest of the secret, in hex, `<digest>`.
2. In a pull request, add the client under `geoff-cloud:pepys` in `infra/Pulumi.prod.yaml`:

   ```yaml
   serviceClientDigests:
     <client_name>: <digest>
   ```

3. Run `bun run preview`. Expect it to create the ConfigMap `pepys-service-tokens`, or to replace it
   when the field held a client already, and to update the StatefulSet `pepys-host`.
4. Merge it. `Deploy prod` applies it once CI passes on `main`, and the pod `pepys-host-0` rolls.
5. Check the API's start log:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys logs pepys-host-0 -c api
   ```

   Expect a line that starts `api listening on` and ends
   `serving /mcp at https://pepys.geoff.cloud/mcp`. The API reads the file before it listens, and
   refuses to start on a file it can't read or parse, with an error line that names the reason.

6. Sign the client in once with its secret, such as with pepys's own `bun verify` `prod` target, as
   pepys's verify skill describes.

To remove a client, delete its line. When it is the last one, delete the whole field.

## End a client's access

Each command below runs in the container `api` of the pod `pepys-host-0`, as the commands of
[Sign a client in to the API](#sign-a-client-in-to-the-api) do.

1. List the live grants, each with its `<grant_id>`:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys exec pepys-host-0 -c api -- /usr/local/bin/pepys-api grants
   ```

2. End one grant, or remove the client with each grant and token it holds:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys exec pepys-host-0 -c api -- /usr/local/bin/pepys-api grants --revoke=<grant_id>
   ssh root@geoffcloud k3s kubectl -n pepys exec pepys-host-0 -c api -- /usr/local/bin/pepys-api clients remove <client_id>
   ```

## Turn on the API's tailnet route

The route is on while [stack config](./workflows.md#change-stack-config) `pepys.tailnetHostname`
names a host: the key `tailnetHostname` in the `geoff-cloud:pepys` object of
`infra/Pulumi.prod.yaml`. These steps use the name `pepys-api.geoff.cloud`. The Traefik of
[nixie](../architecture/workloads/nixie.md) serves the route, so the route needs stack config
`nixie`.

**CAUTION:** The API never checks a credential on `/rpc`. These steps let each device of each
tailnet member run every query of the API. Get the owner's approval before you answer the held run
in step 6.

1. Open a pull request that adds `tailnetHostname: pepys-api.geoff.cloud` to the `geoff-cloud:pepys`
   object in `infra/Pulumi.prod.yaml`.
2. Check that [the exposure registry](../architecture/network/firewalls.md#the-exposure-registry),
   `packages/topology/exposure.json`, has an entry of kind `tailnet-hostname` whose `hostname` is
   the name. When it has none, add the entry in the same pull request. Then run
   `bun run docs:exposure`, which writes the registry's reference table.
3. Run `bun run preview` from the repo root, as [First preview](./development.md#first-preview) sets
   up. Expect no replace. Expect the preview to add these:
   - the certificate `pepys-api-tailnet`;
   - the Secret `pepys-api-tailnet-tls`;
   - the Ingress `pepys-api-tailnet`;
   - the DNS record `pepys-api-tailnet`.

   Expect the preview to update the network policy `pepys-host` and nixie's Traefik release, which
   gains the namespace `pepys`.

   The Pulumi program refuses a setting it cannot serve, and the preview then fails with one of
   these errors:

   | Error ends with                                                                | Fix                                           |
   | ------------------------------------------------------------------------------ | --------------------------------------------- |
   | `must name a host under geoff.cloud`                                           | Use a name under `geoff.cloud`.               |
   | `must differ from "pepys.webhookHostname" and "pepys.apiHostname"`             | Use a name that no public route of pepys has. |
   | `needs a tailnet-hostname entry for <name> in packages/topology/exposure.json` | Add the entry, as step 2 says.                |
   | `needs stack config "nixie": the route goes through nixie's Traefik`           | [Deploy nixie](./nixie.md) first.             |

4. Merge the pull request.
5. Wait for the `Deploy prod` run of the merge. Expect it to hold, because the plan adds a DNS
   record.
6. Answer the held run once its plan matches the preview, as
   [Answer a held run](./prod-apply.md#answer-a-held-run) says.
7. [Check the tailnet route](#check-the-tailnet-route).

### Check the tailnet route

Run each command on a device on the tailnet.

1. Check that the name resolves to the tailnet address of the machine `geoffcloud`:

   ```sh
   getent hosts pepys-api.geoff.cloud
   tailscale ip -4 geoffcloud
   ```

   Expect the same address from both commands.

2. Check that the Ingress exists:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys get ingress pepys-api-tailnet
   ```

   Expect one row with the class `nixie`, the host `pepys-api.geoff.cloud` and the address of
   step 1.

3. Check that the API answers a query under `/rpc`. The query needs no stored row, so run the
   command as written:

   ```sh
   curl -s -w '\n%{http_code}\n' -X POST -H 'content-type: application/json' \
     -d '{"json":{"session":"telemetry:session:none","issuer":"none","subject":"none"}}' \
     https://pepys-api.geoff.cloud/rpc/telemetry_session_model_requests
   ```

   Expect `{"json":[]}`, then `200`. Only the API gives this answer: Traefik answers
   `404 page not found` for a name it serves no route for, and curl fails on the certificate when
   the certificate is not the name's.

4. While [the public route](#turn-on-the-apis-public-route) is on, check that the tailnet name keeps
   `/mcp` closed:

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://pepys-api.geoff.cloud/mcp
   ```

   Expect `403`.

## Turn off the API's tailnet route

**CAUTION:** Each script and person that calls `/rpc` on the tailnet name fails after these steps.
[The boxxy server](../architecture/workloads/boxxy.md) is not one of them: it calls the API's
Service inside the cluster.

1. Open a pull request that deletes the `tailnetHostname` line from the `geoff-cloud:pepys` object
   in `infra/Pulumi.prod.yaml`. Leave the name's entry in
   [the exposure registry](../architecture/network/firewalls.md#the-exposure-registry): the entry
   opens nothing while the key is absent.
2. Run `bun run preview`. Expect it to delete the certificate, the Secret, the Ingress and the DNS
   record that are named `pepys-api-tailnet`, and to update the network policy `pepys-host` and
   nixie's Traefik release.
3. Merge the pull request.
4. Wait for the `Deploy prod` run of the merge. Expect it to hold, because the plan deletes
   resources.
5. Answer the held run once its plan matches the preview, as
   [Answer a held run](./prod-apply.md#answer-a-held-run) says.
6. Check that the Ingress is gone:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys get ingress pepys-api-tailnet
   ```

   Expect `Error from server (NotFound)`.

## Reach `/rpc` while the tailnet route is off

1. Run a port-forward in one terminal, and leave it open:

   ```sh
   ssh -L 8081:localhost:8081 root@geoffcloud k3s kubectl -n pepys port-forward svc/pepys-host 8081
   ```

2. In a second terminal, call `http://localhost:8081/rpc/` wherever a command calls
   `https://pepys-api.geoff.cloud/rpc/`.
