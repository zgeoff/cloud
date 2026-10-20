# The scheduled drift check

The `Drift check` workflow checks prod for drift every day and posts to Discord when it finds any.
It runs a refresh that only previews, so it compares each resource's live state with the state file
and changes neither. It reads with credentials from the 1Password vault `cloud-ci`, each one
read-only or scoped to what the refresh reads. It leaves out the Onidel and Kubernetes resources.
[Infrastructure as code](../architecture/infrastructure-as-code.md#state-and-drift) describes what
the check covers and why. This runbook sets the check up, reads a run, and answers drift.

## What holds what

| Where                               | Holds                                                                                |
| ----------------------------------- | ------------------------------------------------------------------------------------ |
| the 1Password vault `cloud-ci`      | the five items [Create the items](#create-the-items) lists, and nothing else         |
| a 1Password service account         | read access to `cloud-ci` only                                                       |
| the GitHub environment `drift`      | the branch policy `main`; the secret `OP_SERVICE_ACCOUNT_TOKEN`, the account's token |
| the workflow's `schedule` trigger   | the time of the daily run, in UTC                                                    |
| the workflow's `workflow_dispatch`  | a run on demand: `gh workflow run drift-check.yml --ref main`                        |
| the `deploy-prod` concurrency group | one run at a time across the check and the prod apply job                            |

**CAUTION:** The passphrase in `cloud-ci` decrypts every secret in the Pulumi state, and the R2
token reads the state. Together they expose the Onidel API key and the k3s kubeconfig that the state
holds in its provider config, as well as each secret the program generated. Guard the `cloud-ci`
account's token as you guard the `cloud-deploy` one.

## Create the items

Create each item in `cloud-ci` with the exact item and field names, because the workflow reads them
by those names.

| Item                   | Fields                                              | What it is, and its scope                                                                                      |
| ---------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `r2-pulumi-state-read` | `access-key-id`, `secret-access-key`, `backend-url` | an R2 API token with Object Read only, on the state bucket only; `backend-url` is a copy of the `cloud` item's |
| `pulumi-passphrase`    | `credential`                                        | a copy of the `cloud` item, the passphrase that encrypts the state's secrets                                   |
| `cloudflare-read`      | `credential`                                        | a Cloudflare API token with only the read permission groups below                                              |
| `tailscale-read`       | `client-id`, `client-secret`, `tailnet`             | a Tailscale OAuth client with only the scopes `policy_file:read` and `auth_keys:read`, and no tags             |
| `alert-webhook`        | `credential`                                        | a copy of the `cloud` item, the Discord webhook                                                                |

The Cloudflare token holds these permission groups, and no edit group:

- Account, for the account that holds the zone: Cloudflare Tunnel Read; Access: Apps and Policies
  Read; Access: Organizations, Identity Providers, and Groups Read; Workers Scripts Read; Workers R2
  Storage Read.
- Zone, for `geoff.cloud` only: Zone Read; DNS Read; Zone Settings Read.

The vault holds no Onidel key. A refresh that does not run the program configures each provider from
the state, so the check leaves out every Onidel resource and never calls Onidel's API.

## Set up the check

Do these once, in order.

1. In 1Password, create the vault `cloud-ci` and the items in [Create the items](#create-the-items).
2. Create a service account with read access to `cloud-ci` and no other vault.
3. In GitHub, create the environment `drift` under the repo's settings. Limit its deployment
   branches to `main`, and add the account's token as the environment secret
   `OP_SERVICE_ACCOUNT_TOKEN`. Never paste the token into a terminal command line.
4. Dispatch a first run, and wait for it:

   ```bash
   gh workflow run drift-check.yml --ref main
   gh run watch "$(gh run list --workflow drift-check.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
   ```

   Expect the job `check` to pass. A refresh that the token cannot read fails with the provider's
   403 or 401 for that resource, and the run posts `The scheduled drift check failed` to Discord.

## Read a run

```bash
gh run list --workflow drift-check.yml --limit 5
gh run view <run_id> --log
```

The step `Check drift` prints the refresh's plan with each resource that differs. A run ends in one
of three ways:

- It passes: the live state matches the state file for every resource the check reads.
- It fails, and Discord shows `The scheduled drift check found drift in prod`: the refresh found a
  change, and Pulumi exited 7.
- It fails, and Discord shows `The scheduled drift check failed`: the refresh failed, an earlier
  step failed, or the run was cancelled. Read the log for the cause.

## Answer drift

1. Find what changed. From a clean checkout of `main`, run the check by hand with the `cloud` vault,
   which also reads the resources the scheduled check leaves out:

   ```bash
   bun run drift
   ```

2. Decide which side is right. When the live change is wrong, undo it at its source, or apply `main`
   by hand, as [Apply by hand](./workflows.md#apply-by-hand) describes. When the live change is
   right, change the code to match it in a PR.
3. Dispatch the check again, and expect it to pass.

A drift that the prod apply job finds first holds its run, as
[the prod apply job](./prod-apply.md#answer-a-held-run) describes.

## Rotate the check's credentials

The scoped tokens in `r2-pulumi-state-read`, `cloudflare-read` and `tailscale-read` exist only in
`cloud-ci`. To rotate one, mint a new token with the same scope, store it in the item, then revoke
the old token at its source. The copies in `pulumi-passphrase` and `alert-webhook` follow their
`cloud` items: a change to one of those updates its copy here too. The service account's token has
no expiry. To replace it, make a new account, replace the environment secret, then delete the old
account.
