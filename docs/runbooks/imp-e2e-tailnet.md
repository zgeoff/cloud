# imp's e2e nodes on the tailnet

imp's `tailscale` and `moves-tailnet` e2e suites join throwaway impd nodes to the tailnet as
`tag:imp-e2e`. The policy (`infra/tailnet-policy.ts`) lets those nodes reach only each other on
tcp 7070. No grant takes them to `tag:imp`, so a test run cannot reach a live impd such as
`imp-geoffcloud`. Tracked as GEO-228.

## What holds what

| Where                                       | Holds                                                                |
| ------------------------------------------- | -------------------------------------------------------------------- |
| the tailnet policy (Pulumi)                 | the tag `tag:imp-e2e`, owned by admins and itself; its one grant     |
| the OAuth client `imp-e2e` (made by hand)   | scope `auth_keys` only, tag `tag:imp-e2e` only                       |
| imp's own 1Password vault (not `cloud`)     | the client's ID and secret                                           |
| vault `cloud`, item `imp-tailscale-authkey` | the `tag:imp` key, still used by imp's dev instances, not by its e2e |

imp's e2e harness passes the client secret to `tailscale up` as the auth key, with
`?ephemeral=true&preauthorized=true` and `--advertise-tags=tag:imp-e2e`. Each node is ephemeral, so
Tailscale removes it soon after it goes offline.

## Why the client is made by hand

Pulumi's own OAuth client (`op://cloud/tailscale-oauth`) has the scopes `devices:core`,
`devices:core:read`, `devices:posture_attributes`, `policy_file`, `dns` and `auth_keys`. It has no
`oauth_keys` scope, so it cannot create an OAuth client: the API answers `404 not found` to a
`keyType: "client"` request (checked 2026-10-10). The pinned provider (`@pulumi/tailscale` 0.29.1)
has an `OauthClient` resource, but it would need that wider credential. A hand-made client also
keeps its secret out of this public repo's Pulumi state.

## Create or replace the client

1. Apply the policy first, so `tag:imp-e2e` exists.
2. In the Tailscale admin console's
   [trust credentials](https://console.tailscale.com/admin/settings/trust-credentials), add a
   credential of type OAuth: description `imp-e2e`, scope **Auth Keys** (write) only, tag
   `tag:imp-e2e` only.
3. Store the client ID and secret in imp's own 1Password vault, the item imp's e2e harness reads
   (imp's `docs/guides/configuration.md`). Never paste the secret into a terminal command line.
4. Revoke the old client, if any, in the same console page.

The secret does not expire. Replace it when it may have leaked.

## Check the isolation

From a `tag:imp-e2e` node, `tailscale ping imp-geoffcloud` must fail: the policy gives the node no
route to it. imp's e2e PR for GEO-228 records that output.
