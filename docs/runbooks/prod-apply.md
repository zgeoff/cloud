# The prod apply job

The `Deploy prod` workflow applies each merged change to a Pulumi input once CI passes on `main`,
unless its guard holds the plan for a person.
[Infrastructure as code](../architecture/infrastructure-as-code.md#the-apply-job) describes how it
decides, what the guard holds, and why. This runbook sets the job up, reads a run, and answers a
held one.

**CAUTION:** An apply changes the live estate. Read every held plan in full before you dispatch it.

## What holds what

| Where                                         | Holds                                                                                |
| --------------------------------------------- | ------------------------------------------------------------------------------------ |
| the 1Password vault `cloud-deploy`            | a copy of each item `.env` references, under the same item and field names           |
| a 1Password service account                   | read access to `cloud-deploy` only                                                   |
| the GitHub environment `prod`                 | the branch policy `main`; the secret `OP_SERVICE_ACCOUNT_TOKEN`, the account's token |
| the `prod` environment's variables            | `TS_DEPLOY_CLIENT_ID` and `TS_DEPLOY_AUDIENCE`, the federated identity's two values  |
| a Tailscale federated identity (made by hand) | scope Auth Keys (write), tag `tag:cloud-deploy`, trusted for the `prod` environment  |
| the tailnet policy (Pulumi)                   | the tag `tag:cloud-deploy`, owned by admins and itself; its one grant, to k3s's API  |
| the tag `deployed/prod`                       | the last revision applied, lightweight, moved only by the job after it passes        |

## Set up the job

Do these once, in order. Steps 1 to 3 need no change to the repo.

1. In 1Password, create the vault `cloud-deploy`. Copy into it each item that `.env` references,
   with the same item name and field names. This lists them:

   ```bash
   grep -o 'op://cloud/[^/]*' .env | sort -u
   ```

   The vault holds nothing else.

2. Create a service account with read access to `cloud-deploy` and no other vault. In GitHub, create
   the environment `prod` under the repo's settings. Limit its deployment branches to `main`, and
   add the account's token as the environment secret `OP_SERVICE_ACCOUNT_TOKEN`. Never paste the
   token into a terminal command line.
3. Apply the tailnet policy that adds `tag:cloud-deploy`, by hand, as
   [workflows](./workflows.md#apply-by-hand) describes. The owner reviews its policy diff first.
4. In the Tailscale admin console's
   [trust credentials](https://console.tailscale.com/admin/settings/trust-credentials), add a
   credential of type OpenID Connect: issuer GitHub, subject `repo:<owner>/<repo>:environment:prod`
   for this repo, scope Auth Keys (write) only, tag `tag:cloud-deploy` only. Add its client ID and
   audience to the `prod` environment as the variables `TS_DEPLOY_CLIENT_ID` and
   `TS_DEPLOY_AUDIENCE`.
5. [Set `deployed/prod`](#set-deployedprod-once) at the last revision applied by hand.

The next push to `main` that changes a Pulumi input runs the whole job. Until step 5, every run
fails at its decision with `fatal: Needed a single revision`.

## Set deployed/prod once

The job needs a baseline before its first run: the last revision anyone applied. Every later move is
the job's own.

1. Find the revision of the last apply by hand. Its PR or issue records it with its drift results.
2. From a clean checkout of that revision, check that it is still the live state:

   ```bash
   bun run drift
   ```

   Expect exit 0. On any change, find the revision that matches the live state, or apply by hand
   first.

3. Set and push the tag. Keep it lightweight, with no `-a` or `-m`, because the job moves it as a
   plain commit reference:

   ```bash
   git tag deployed/prod <revision>
   git push origin refs/tags/deployed/prod
   ```

## Read a run

```bash
gh run list --workflow deploy-prod.yml --limit 5
gh run view <run_id> --log
```

A run that applied ends its summary with `deployed/prod moved to <revision>.`, and its log shows
both drift checks. Link the run on the PR or issue as the record of the apply. A run whose decision
printed `No Pulumi input changed since deployed/prod, so nothing applied.` changed nothing.

## Answer a held run

A held run fails at the step `Hold for a manual dispatch`, and Discord shows
`The prod apply is held for a manual dispatch`. Its summary lists each reason.

1. Read the held plan. Run a preview from a clean checkout of the held revision to see each change
   in full:

   ```bash
   bun run sdk:build
   bun run preview -- --refresh --diff
   ```

2. To apply it, dispatch the workflow on `main` with main's tip, which must be the held revision.
   The dispatch refuses a revision that has no green CI run of a push to `main`:

   ```bash
   gh workflow run deploy-prod.yml --ref main -f revision="$(git rev-parse origin/main)"
   ```

   The dispatched run previews again and applies whatever it plans, with no guard. If `main` moved
   on, answer the newest held run instead: its plan holds every change since the tag. A push to
   `main` while your dispatch still waits in the queue replaces it, and that push's run holds again
   and alerts: dispatch again once it ends.

3. To drop the change, revert it in a PR. The revert's own run then finds nothing to hold.

Never dispatch a held plan that replaces imp's `tag:imp` key. The apply writes the new key into the
`cloud` vault, which the job's account cannot write, so the dispatched apply fails partway and the
vault keeps the old key. [Apply it by hand](./workflows.md#apply-by-hand).

## Rotate the job's credentials

A rotation of an item `.env` references updates the item in `cloud` and its copy in `cloud-deploy`,
or the job reads the old value. The service account's token expires on the date set when it was
made: make a new account, replace the environment secret, then delete the old account.
