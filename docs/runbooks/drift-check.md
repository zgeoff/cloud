# The scheduled drift check

A systemd timer on geoffcloud checks prod for drift every day, and posts to Discord when it finds
drift or the run fails. The check runs a refresh that only previews, so it compares each resource's
live state with the state file and changes neither. It leaves out the Onidel and Kubernetes
resources. It reads a root-only credentials file on the host, whose values come from the 1Password
vault `cloud`, and no GitHub workflow reads that vault.
[Infrastructure as code](../architecture/infrastructure-as-code.md#state-and-drift) describes what
the check covers and why it runs on the host. This runbook sets the check up, runs it by hand, reads
a run, and answers drift.

## What holds what

| Where                                                      | Holds                                                                          |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------ |
| the 1Password vault `cloud`                                | the items [Create the items](#create-the-items) lists                          |
| `/var/lib/tank-cloud/host-secrets/drift-check/credentials` | the check's nine values, mode 0400 root, on the encrypted host-secrets dataset |
| `drift-check.timer`                                        | the daily start time, which the host's NixOS module sets                       |
| `drift-check.service`                                      | one run: the wait for a Deploy prod run, the refresh and the alert             |
| `/var/lib/drift-check`                                     | the service's state directory, which holds the Pulumi plugins it downloads     |

**CAUTION:** The credentials file holds the passphrase, which decrypts every secret in the Pulumi
state, and the R2 token, which reads the state. Together they expose the Onidel API key and the k3s
kubeconfig that the state holds in its provider config, as well as each secret the program
generated. Never copy the file off the host, and never print it.

The service runs as a dynamic user, with no capabilities, and reads the file through systemd's
credentials. The check gets every value but the webhook in its environment, and the alert gets only
the webhook. systemd mounts a dynamic user's state directory with noexec, so the unit lists that
directory in `ExecPaths=`, and the plugins it downloads there can start. Until the file exists,
systemd skips the service, so a run before the setup leaves nothing in Discord.

The check and the Deploy prod job share no lock, because GitHub's concurrency group cannot hold a
service on the host. A run therefore guards against an apply by asking GitHub. Before the check, it
waits while a Deploy prod run is queued or in progress. After a check that fails, it asks again, and
when a Deploy prod run was queued, in progress or changed during the check, it waits and runs the
check once more, then reports that second check. A drift alert therefore never comes from an apply
that overlapped the first check. One overlap stays possible: a clean check during an apply reports
clean, and the next day's run reads the state the apply left.

## Create the items

The install script reads these items in `cloud` by their exact item and field names.

| Item                   | Fields                                              | What it is, and its scope                                                                                                |
| ---------------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `r2-pulumi-state-read` | `access-key-id`, `secret-access-key`, `backend-url` | an R2 API token with Object Read only, on the state bucket only; `backend-url` is a copy of the `r2-pulumi-state` item's |
| `pulumi-passphrase`    | `credential`                                        | the passphrase that encrypts the state's secrets, the item `.env` reads                                                  |
| `cloudflare-read`      | `credential`                                        | a Cloudflare API token with only the read permission groups below                                                        |
| `tailscale-read`       | `client-id`, `client-secret`, `tailnet`             | a Tailscale OAuth client with only the scopes `policy_file:read` and `auth_keys:read`, and no tags                       |
| `alert-webhook`        | `credential`                                        | the Discord webhook, the item `.env` reads                                                                               |

The Cloudflare token holds these permission groups, and no edit group:

- Account, for the account that holds the zone: Cloudflare Tunnel Read; Access: Apps and Policies
  Read; Access: Organizations, Identity Providers, and Groups Read; Workers Scripts Read; Workers R2
  Storage Read.
- Zone, for `geoff.cloud` only: Zone Read; DNS Read; Zone Settings Read.

The file holds no Onidel key. A refresh that does not run the program configures each provider from
the state, so the check leaves out every Onidel resource and never calls Onidel's API.

## Set up the check

Do these once, in order.

1. In 1Password, create the items `r2-pulumi-state-read`, `cloudflare-read` and `tailscale-read` in
   `cloud`, as [Create the items](#create-the-items) describes. `pulumi-passphrase` and
   `alert-webhook` exist in `cloud`, because `.env` reads them.
2. From a machine where `op` reads `cloud`, install the credentials file on the host:

   ```bash
   bash scripts/install-drift-check-credentials.sh
   ```

   Expect `installed: /var/lib/tank-cloud/host-secrets/drift-check/credentials (9 lines, mode 400)`.
   The script sends the values on SSH's standard input, never on a command line.

3. Switch the host to a `main` that holds the drift check, as
   [Switch the host](./workflows.md#switch-the-host) describes.
4. Run the check once by hand, as [Run the check by hand](#run-the-check-by-hand) describes, and
   expect it to pass.

## Run the check by hand

1. Start a run, and wait for it to end:

   ```bash
   ssh -o BatchMode=yes root@geoffcloud systemctl start drift-check.service
   ```

   The command returns when the run ends. It exits 0 when the check found no drift, and otherwise
   prints `Job for drift-check.service failed because the control process exited with error code.`
   and exits 1. The first run downloads the Pulumi plugins that the state records, so it takes
   longer than later ones.

2. Read the run's log:

   ```bash
   ssh -o BatchMode=yes root@geoffcloud journalctl -u drift-check.service -n 200 --no-pager
   ```

   Expect its last line from the check to be `run-host-drift-check: no drift`.
   [Read a run](#read-a-run) covers every other ending.

## Read a run

A run's log is in the journal on the host, and in Loki as
`{job="journal", unit="drift-check.service"}`. Each Discord alert ends with the command that prints
its own run, such as
`on geoffcloud: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=<invocation_id>`. To see
when the timer last ran and runs next:

```bash
ssh -o BatchMode=yes root@geoffcloud systemctl list-timers drift-check.timer --no-pager
```

The refresh's plan in the log shows each resource that differs. A run ends in one of five ways:

- It passes, with `run-host-drift-check: no drift`: the live state matches the state file for every
  resource the check reads.
- It fails with status 7, the log ends with `run-host-drift-check: posted the drift alert`, and
  Discord shows `The scheduled drift check found drift in prod`: the refresh found a change.
  [Answer drift](#answer-drift).
- It fails with another status, the log ends with `run-host-drift-check: posted the failed alert`,
  and Discord shows `The scheduled drift check failed`: the refresh failed, a provider plugin could
  not start, the check ran out of time (status 124), the credentials file is incomplete, a Deploy
  prod run stayed in progress past the check's wait, or another step failed, with
  `run-host-drift-check: the run failed (exit <status>)` in the log. The lines before the alert give
  the cause.
- It fails, and the log ends with `run-host-drift-check: the alert failed (exit <status>)`: Discord
  refused the post or the host could not reach it. Read the check's own result in the lines before.
- It never starts, and `systemctl status drift-check.service` shows that its `ConditionPathExists=`
  was not met: the credentials file is missing. Install it as [Set up the check](#set-up-the-check)
  describes.

## Answer drift

1. Find what changed. From a clean checkout of `main`, run the check by hand with the `cloud` vault,
   which also reads the resources the scheduled check leaves out:

   ```bash
   bun run drift
   ```

2. Decide which side is right. When the live change is wrong, undo it at its source, or apply `main`
   by hand, as [Apply by hand](./workflows.md#apply-by-hand) describes. When the live change is
   right, change the code to match it in a PR.
3. When you changed the code, record the live change in the state. After the PR merges, the prod
   apply job's first drift check finds the same change and holds the run. Read the held plan and
   dispatch it, as [Answer a held run](./prod-apply.md#answer-a-held-run) describes. Its apply
   refreshes first, so it writes the live value into the state. Until then, every scheduled check
   reports the same drift.
4. Run the check by hand again, as [Run the check by hand](#run-the-check-by-hand) describes, and
   expect it to pass.

A drift that the prod apply job finds first holds its run, as
[the prod apply job](./prod-apply.md#answer-a-held-run) describes.

## Rotate the check's credentials

The scoped tokens in `r2-pulumi-state-read`, `cloudflare-read` and `tailscale-read` exist only for
the check. To rotate one, mint a new token with the same scope, store it in its item, run
`bash scripts/install-drift-check-credentials.sh` again, then revoke the old token at its source.
After a change to `pulumi-passphrase` or `alert-webhook`, run the script again too. The service
reads the file at each start, so the next run takes the new values with no restart.
