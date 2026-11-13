# pepys: the API's public route and its clients

Open the API of [pepys](../architecture/workloads/pepys.md) to MCP clients on the internet, and sign
a client in to it. Use [Turn on the API's public route](#turn-on-the-apis-public-route) once, while
the stack config holds no `pepys.apiHostname`. Use
[Sign a client in to the API](#sign-a-client-in-to-the-api) for the owner's first passkey and for
each MCP client after it.
[The API's public route](../architecture/workloads/pepys.md#the-apis-public-route) explains what the
route is made of and what each path checks.

## Turn on the API's public route

**CAUTION:** This adds a public route. Its `Deploy prod` run holds on the tunnel route change until
the owner approves it, as [the prod apply job](./prod-apply.md) describes.

1. In the pull request that pins a `cloud-pepys` image of pepys 0.3.1 or later, add
   `apiHostname: pepys.geoff.cloud` to the `geoff-cloud:pepys` object in `infra/Pulumi.prod.yaml`.
   The Pulumi program accepts an image of pepys 0.3.0, but the API in that image stops at start.
2. Run `bun run preview`. Expect it to add the volume claim `pepys-auth`, the Cloudflare Access
   policy `pepys-api-owner`, the Access application `pepys-api-sign-in` and the DNS record
   `pepys-api`. Expect it to update the host's StatefulSet, the host's network policy and the shared
   tunnel's configuration. Expect no replace.
3. Merge the pull request.
4. Approve the held `Deploy prod` run once its plan matches the preview, as
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

7. Check that the MCP alias at `/` takes only a POST. cloudflared routes on the path alone, so the
   API refuses the other methods:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' https://pepys.geoff.cloud/
   ```

   Expect `405`.

8. Sign a client in, as [Sign a client in to the API](#sign-a-client-in-to-the-api) says.

## Sign a client in to the API

The API's admin commands run in the API's container, beside the running server, on `mcp-auth.db`,
the database of the API's OAuth server. The commands need the API's public route, so
[turn on the API's public route](#turn-on-the-apis-public-route) first. Each command below runs
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

   Cloudflare Access asks for the owner's one-time PIN before the page loads. Expect the command of
   step 1 to list the new passkey.

3. Add the client, with a fixed callback port, `<port>`, of your choice:

   ```sh
   ssh root@geoffcloud k3s kubectl -n pepys exec pepys-host-0 -c api -- /usr/local/bin/pepys-api clients add 'Claude Code' --redirect-uri http://localhost:<port>/callback
   ```

   Expect a client ID, `<client_id>`.

4. In Claude Code, add the MCP server `https://pepys.geoff.cloud/mcp` over HTTP, with `<client_id>`
   in `--client-id` and `<port>` in `--callback-port`. Leave out `--client-secret`, because every
   client is public. Expect the first connection to open the owner's browser on `/oauth2/authorize`.

To end a client's access, run `pepys-api` the same way with one of these arguments:

- `grants` lists the live grants, each with its `<grant_id>`.
- `grants --revoke=<grant_id>` ends one grant.
- `clients remove <client_id>` removes a client with each grant and token it holds.
