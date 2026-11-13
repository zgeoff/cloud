# pepys: the API's public route and its clients

Open the API of [pepys](../architecture/workloads/pepys.md) to MCP clients on the internet, sign a
client in to it, and end a client's access.
[Turn on the API's public route](#turn-on-the-apis-public-route) adds the route to a deployment that
has none. [Sign a client in to the API](#sign-a-client-in-to-the-api) enrolls the owner's passkey
and adds an MCP client, and [End a client's access](#end-a-clients-access) removes one.
[The API's public route](../architecture/workloads/pepys.md#the-apis-public-route) explains what the
route is made of, and
[the pepys API's route boundary](../architecture/network/public-ingress.md#the-pepys-apis-route-boundary)
lists what each path checks.

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
