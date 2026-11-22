# Troubleshooting

Look up a failure by the message or symptom you see in a Pulumi run, a 1Password login, a check, a
host switch or an alert, then apply its fix.

## Pulumi runs

### `stack config "cluster" is unset`

Set `cluster` to say whether the stack manages the k3s cluster. Use `managed`, the `prod` value. Set
`none` only on a stack that has never had a cluster, because with `none` the program plans to delete
every cluster resource:

```sh
cd infra
op run --env-file=../.env -- pulumi config set --stack prod cluster managed
```

### `cluster is managed, but K3S_KUBECONFIG is empty`

The run did not resolve `.env`, or the reference is missing. Run through the root scripts, which
wrap `op run`. Check that `.env` has `K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml`. To
store the item and add the line, run `bash scripts/connect-k3s.sh`.

**CAUTION:** Never set `cluster` to `none` to get past this error. With `none`, the program plans to
delete every cluster resource.

### `CLOUDFLARE_ACCOUNT_ID is unset` or `is blank`

The run did not go through `op run`, or the reference resolved to an empty value. Use
`bun run preview` or `bun run up`, or prefix the command with `op run --env-file=../.env --` from
`infra/`.

### `discordAlerts is on, but ALERT_WEBHOOK_URL is empty`

`discordAlerts` is true, but the webhook did not resolve. Check the `alert-webhook` item and the
`ALERT_WEBHOOK_URL` line in `.env`, or turn the flag off.

### `discordAlerts is on, but ALERT_MENTION_USER_ID is empty` or `is not a Discord user ID`

`discordAlerts` is true, but the Discord user that a critical alert mentions did not resolve to a
user ID. Check that the `mention-user-id` field of the `alert-webhook` item holds the user's numeric
ID, from **Copy User ID** in Discord's developer mode. Check it in `cloud`, and in `cloud-deploy`
for the apply job.

### `x509: certificate signed by unknown authority`

The kubeconfig in `k3s-kubeconfig` does not match the cluster, such as after k3s was rebuilt. The
run fails and changes nothing. Store the new kubeconfig with `bash scripts/connect-k3s.sh`. After a
cluster rebuild, follow
[the cluster section of the restore runbook](./restore-geoff-cloud.md#5-rebuild-the-cluster).

### `atcGateway.daemons.<name>.daemonID is unset`, or another `atcGateway` error

These come from the inputs group in `infra/inputs/` when `atcGateway` is set: the stack config's
schema, then each daemon's token. Each failing field gets one line, which starts with the field's
path and gives its fix. Apply that fix.

### The preview shows changes on a clean `main`

If every merged change is applied, that is drift: the live resources differ from the code, and
`bun run drift` fails on it. A merged change that nobody has applied yet shows the same way, so
compare the changes with the ones reviewed on its PR. Find the cause before you apply. Get the
owner's review for a change to the tailnet policy, because the apply replaces the whole policy file.

## 1Password

### `op` fails to authenticate

The service-account token in `OP_SERVICE_ACCOUNT_TOKEN` has expired or lacks the `cloud` vault. Mint
a new token scoped to the `cloud` vault, and set it in the environment.

## CI

### `format:check` fails

Run `bun run format`, which rewrites the files, including Markdown tables, and commit the result.

## Host

### A switch fails with a host-key or SSH error

The switch container reads `~/.ssh/known_hosts`, and SSH runs in batch mode. SSH to
`root@geoffcloud` once from your machine to record the host key, then retry.

### A Nix command in the container cannot write to `/src`

The repo mounts read-only. Build with `nix build --no-link`, as in
[Switch the host](./workflows.md#switch-the-host).

### `ImpdLocalHealthDown` or `ImpdLocalHealthStale` fires

`Down` means impd answers its loopback `/health` with something other than 200 and `ready: true`.
Check `ssh root@geoffcloud systemctl status imp-host` and impd's logs in Loki.

`Stale` means the probe stopped reporting. Check the timer with
`ssh root@geoffcloud systemctl status impd-local-health.timer`, and check that node-exporter runs in
`observability`.

### `HostBehindLatestBuild` or `HostBuildLagStale` fires

`HostBehindLatestBuild` means that, for over a day, the host has run an older system or imp than the
latest green build of `main`. The alert's `part` label is `system` or `imp`.
[Switch the host](./workflows.md#switch-the-host) from `main`, and for a change to imp, copy impd's
database first, as [Upgrade imp](./workflows.md#upgrade-imp) describes. The alert clears at the next
hourly check after the switch. When `part` is `system` and the host runs `main`'s build, the last
switch did not go through `scripts/switch-geoffcloud.sh`, such as a rollback, and left no switch
record. The next switch records one. When `part` is `imp` and the system is current, imp-host runs a
different imp from its pin, or does not answer. Compare
`ssh root@geoffcloud podman exec imp-host impz info` with the pin, and check
`ssh root@geoffcloud systemctl status imp-host`.

`HostBuildLagStale` means the check stopped reporting, or that the host runs a build without it.
Check `ssh root@geoffcloud systemctl status host-build-lag.service` and its journal. The check reads
GitHub's API without a token, so GitHub's rate limit for anonymous requests from the host's address
can fail it.

### `CloudflaredNoConnections` fires

No cloudflared pod holds a tunnel connection, or Prometheus cannot scrape cloudflared's metrics.
Check the pods with `ssh root@geoffcloud k3s kubectl -n ingress get pods`, and their logs in Loki.
To tell the two apart, look at the external health check: it reports `tunnel-down` when the tunnel
is down, and stays healthy when only the metrics fail.

### `ATCDaemonUnreachable` fires

A pod cannot open a TCP connection to an atc daemon in `atcGateway.daemons`, or the probe reports
nothing. Find the daemon's address in the alert's summary. The probe's `target` label is
`atc-daemon` for geoffcloud and `atc-daemon-<name>` for any other. When the connection fails, the
gateway cannot reach that daemon either. For geoffcloud's daemon, check each cause in turn:

1. The daemon is down. Check `ssh root@geoffcloud systemctl status atc-daemon`.
2. The host firewall drops the pod's traffic to port 8415, which arrives on `cni0` from
   `10.42.0.0/16`. Check `ssh root@geoffcloud nft list table inet cloud_host`.
3. The daemon's `address` in `atcGateway.daemons` is wrong. Compare it with the address the daemon
   listens on, from `ssh root@geoffcloud ss -tlnp`.

If the probe reports nothing, check the `atc-daemon-probe` pods with
`ssh root@geoffcloud k3s kubectl -n observability get pods`.
