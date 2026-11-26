# imp's e2e nodes

imp's end-to-end suites run off the production tailnet, on the test tailnets in impz's
[e2e tailnet runbook](https://github.com/zgeoff/impz/blob/main/docs/runbooks/e2e-tailnet.md). The
production policy (`infra/tailnet/tailnet-policy.ts`) therefore holds no tag and no grant for a test
node.

A dev instance started with `IMP_TAILSCALE_OP=1` asks the production tailnet for a key that carries
`tag:imp-e2e`. The production policy gives that tag no owner, so no OAuth client can mint the key,
and the dev instance stays off the production tailnet.

## Check the production tailnet

Run this check after a change to the tailnet policy, and whenever an unknown node shows up on the
production tailnet.

1. Run the policy's tests from a clean checkout of `main`:

   ```bash
   bun test infra/tailnet/tailnet-policy.test.ts
   ```

   Expect every test to pass. The first test pins the whole policy, and the pinned tag owners hold
   no `tag:imp-e2e`.

2. In the Tailscale admin console's
   [access controls](https://console.tailscale.com/admin/acls/file), search the live policy file for
   `imp-e2e`. Expect no match.

   A match means the live policy lags `main`. Apply `main` with
   [the prod apply job](./prod-apply.md), then search again.

3. In the admin console's
   [trust credentials](https://console.tailscale.com/admin/settings/trust-credentials), look for an
   OAuth client with the description `imp-e2e`. Expect none.

   Revoke any such client on the same page. No suite and no policy entry uses it.
