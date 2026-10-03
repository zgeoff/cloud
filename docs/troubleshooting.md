# Troubleshooting

Known failures, by the message or symptom you see.

## Pulumi runs

### `stack config "cluster" is unset`

The stack must say whether it manages the k3s cluster. Set it to `managed` (the `prod` value) or
`none`:

```sh
cd infra
op run --env-file=../.env -- pulumi config set --stack prod cluster managed
```

### `cluster is managed, but K3S_KUBECONFIG is empty`

The run did not resolve `.env`, or the reference is missing. Run through the root scripts, which
wrap `op run`. Check that `.env` has `K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml`;
`bash scripts/connect-k3s.sh` stores the item and adds the line.

**CAUTION:** Never set `cluster` to `none` to get past this error. With `none`, the program plans to
delete every cluster resource.

### `CLOUDFLARE_ACCOUNT_ID is unset`

The run did not go through `op run`. Use `bun run preview` or `bun run up`, or prefix the command
with `op run --env-file=../.env --` from `infra/`.

### `discordAlerts is on, but ALERT_WEBHOOK_URL is empty`

`discordAlerts` is true, but the webhook did not resolve. Check the `alert-webhook` item and the
`ALERT_WEBHOOK_URL` line in `.env`, or turn the flag off.

### `x509: certificate signed by unknown authority`

The kubeconfig in `k3s-kubeconfig` does not match the cluster, such as after k3s was rebuilt. The
run fails and changes nothing. Store the new kubeconfig with `bash scripts/connect-k3s.sh`. After a
cluster rebuild, follow
[the cluster section of the restore runbook](./runbooks/restore-geoff-cloud.md#5-rebuild-the-cluster).

### `atcGateway.daemonID is unset`, or another `atcGateway` error

**PENDING.** These come from `infra/require-atc-gateway-inputs.ts` when `atcGateway` is set. Each
message names its fix. The gateway's order of steps is in
[the operator checklist](./runbooks/atc-gateway-operator-checklist.md).

### The preview shows changes on a clean `main`

If every merged change is applied, that is drift: the live resources differ from the code, and
`bun run drift` fails on it. A merged change that nobody has applied yet shows the same way; compare
the changes with the ones reviewed on its PR. Find the cause before an apply. A change to the
tailnet policy needs Geoff's review, because the apply replaces the whole policy file.

## 1Password

### `op` fails to authenticate

The service-account token in `OP_SERVICE_ACCOUNT_TOKEN` has expired or lacks the `cloud` vault. Mint
a new token scoped to the `cloud` vault, and set it in the environment.

## CI

### `Check AGENTS.md Drift` fails

`AGENTS.md` is generated. CI rebuilds it and fails on any difference. Edit `agents/project.md`,
never `AGENTS.md`, then regenerate and commit both:

```sh
bun run build:agents
```

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
`ssh root@geoffcloud systemctl status impd-local-health.timer`, and that node-exporter runs in
`observability`.

### `CloudflaredNoConnections` fires

No cloudflared pod holds a tunnel connection, or Prometheus cannot scrape cloudflared's metrics.
Check the pods with `ssh root@geoffcloud k3s kubectl -n ingress get pods`, and their logs in Loki.
If the tunnel is down, the external health check reports it from outside as `tunnel-down`; if only
the metrics fail, the external check stays healthy.

### `ATCDaemonUnreachable` fires

A pod cannot open a TCP connection to the atc daemon at `atcGateway.daemonAddress`, or the probe
reports nothing. The gateway cannot reach the daemon then either. Three causes:

1. The daemon is down. Check `ssh root@geoffcloud systemctl status atc-daemon`.
2. The host firewall drops the pod's path: port 8415 from `cni0`, source `10.42.0.0/16`. Check
   `ssh root@geoffcloud nft list table inet cloud_host`.
3. `atcGateway.daemonAddress` is wrong. Compare it with the address the daemon listens on, from
   `ssh root@geoffcloud ss -tlnp`.

If the probe reports nothing, check the `atc-daemon-probe` pods with
`ssh root@geoffcloud k3s kubectl -n observability get pods`.
