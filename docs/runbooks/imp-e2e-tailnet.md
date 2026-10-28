# imp's e2e nodes

imp's end-to-end suites run off the production tailnet, so the production policy
(`infra/tailnet/tailnet-policy.ts`) holds no tag and no grant for a test node. The tailscale, egress
and moves-tailnet suites run on a Headscale control server in a container of the run's own. The
tailnet-names suite runs on a test tailnet, a Tailscale tailnet that holds no production service.
impz's [e2e tailnet runbook](https://github.com/zgeoff/impz/blob/main/docs/runbooks/e2e-tailnet.md)
owns both tailnets and their policies. The 1Password vault `imp-e2e` holds the test tailnet's OAuth
clients and no credential of the production tailnet.

A dev instance started with `IMP_TAILSCALE_OP=1` asks the production tailnet for a key that carries
`tag:imp-e2e`. The production policy gives that tag no owner, so no OAuth client can mint the key,
and the dev instance never joins the production tailnet.

## Check the production tailnet

1. Run the policy's tests from a clean checkout of `main`:

   ```bash
   bun test infra/tailnet/tailnet-policy.test.ts
   ```

   Expect every test to pass. The first test pins the whole policy, and its tag owners hold no
   `tag:imp-e2e`.

2. In the Tailscale admin console's
   [access controls](https://console.tailscale.com/admin/acls/file), search the live policy file for
   `imp-e2e`. Expect no match.
3. In the admin console's
   [trust credentials](https://console.tailscale.com/admin/settings/trust-credentials), look for an
   OAuth client with the description `imp-e2e`. Expect none.
