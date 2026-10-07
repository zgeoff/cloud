# Workflows

Common tasks on geoff.cloud. Each change lands through a squash PR to `main`; run live changes from
a clean checkout of `main`.

**CAUTION:** No live change without a preview first. A change that costs money, deletes data or
cannot be undone needs Geoff's approval of its exact effect.

## Change infrastructure

1. Edit `infra/`, and open a PR.
2. Preview it. The preview changes nothing:

   ```sh
   bun run sdk:build
   bun run preview
   ```

   Read every replace and delete. If the preview changes the tailnet policy, Geoff reviews the diff
   first: Pulumi replaces the whole policy file.

3. Check the baseline from a clean checkout of the last deployed revision:

   ```sh
   bun run drift
   ```

   It exits non-zero on any change, so it expects 0 changes only against the deployed code. A clean
   `main` serves as the baseline only when it is fully applied: it can hold other merged changes
   that nobody has applied. Record the revision and the result. Resolve drift before you go on.

4. After the merge, from a clean current `main`, preview against the live state:

   ```sh
   bun run preview -- --refresh
   ```

   Expect exactly the intended changes, reviewed on their PRs, and nothing else.

5. Apply:

   ```sh
   bun run up
   ```

6. Run `bun run drift` again, and expect 0 changes. Record both drift results on the PR or issue.

Pass Pulumi flags after `--`, such as `bun run preview -- --diff`.

### Change stack config

Stack config lives in `infra/Pulumi.prod.yaml`, under the namespace `geoff-cloud`. Set a key from
`infra/`, through `op run` so Pulumi can decrypt the stack:

```sh
cd infra
op run --env-file=../.env -- pulumi config set --stack prod <key> <value>
```

Land the YAML change through a PR, then preview and apply as above.
[The reference](./reference.md#stack-config) lists the keys.

## Switch the host

The host is the flake in `nixos/`. Build first, then switch, from a clean checkout of `main`. Both
run in a `nixos/nix` container on the host network, so you need no local Nix. Tailscale SSH
authenticates `root@geoffcloud`. The Docker volume `geoffcloud-nix-store` keeps the Nix store
between runs.

Run the script, which builds, then switches only after the build exits 0:

```sh
bash scripts/switch-geoffcloud.sh               # build, switch, check the host runs the build
bash scripts/switch-geoffcloud.sh --build-only  # build and print the system path
```

1. It refuses a branch other than `main`, uncommitted changes, a `main` behind `origin/main`, or any
   git command that fails.
2. It builds a `git archive` snapshot of that commit with `nix build --no-link`, so untracked files
   and edits made during the run never reach the build. A failed build stops the script, and nothing
   reaches the host.
3. It copies the built store path to the host with `nix copy`, sets the system profile to it and
   runs its `switch-to-configuration switch` under `systemd-run`, as `nixos-rebuild` does. The flake
   is not evaluated again.
4. It fails unless the host's `/run/current-system` is the built path, then prints
   `systemctl --failed`, which should list nothing.

`bash scripts/test-switch-geoffcloud.sh` (part of `bun run test:scripts`) checks the gate with stub
`docker` and `ssh`. After a switch, `ssh root@geoffcloud k3s kubectl get nodes` should show the node
`Ready`.

Before a risky host change, take an Onidel snapshot of the root disk:

```sh
op run --env-file=.env -- bash scripts/snapshot-geoffcloud.sh pre-<change>
```

The flake also has checks: `atc-daemon` and `impd-local-health` for its modules, `test-utils` for
the helpers and the stand-in impd they share, and `impd-restore` and `impd-restore-seams`, NixOS VM
rehearsals of `scripts/restore-impd-db.sh` on one shared machine that need KVM: `impd-restore-seams`
holds the errors only a stand-in `systemctl` or `cmp` reaches. `bun run test:nixos` builds every
check the flake declares in a `nixos/nix` container, from a snapshot of the working tree's tracked
and unignored files. Its Nix store is the Docker volume `cloud-nixos-checks-store`, never the
switch's `geoffcloud-nix-store`. `bun run test:nixos atc-daemon` builds one check.

## Upgrade imp

imp is pinned in two places, and both move together:

| Pin                  | File                                                                                  |
| -------------------- | ------------------------------------------------------------------------------------- |
| imp's NixOS module   | the `imp` input in `nixos/flake.nix`, and `nixos/flake.lock`                          |
| the `imp-host` image | `services.imp.image` in `nixos/hosts/geoffcloud/configuration.nix`, by tag and digest |

1. Update both pins in a PR. Read imp's release notes for migrations and new host settings.
2. Copy impd's database. Never tar the live files:

   ```sh
   bash scripts/copy-impd-db.sh imp-<old version>-pre-<new version>
   ```

   The copy and its `COPY-INFO` land in `/root/imp-db-backups/`.
   [The restore runbook](./runbooks/restore-geoff-cloud.md#2-roll-impds-database-back) puts a copy
   back.

3. [Switch the host](#switch-the-host). The switch restarts impd.
4. Check: `ssh root@geoffcloud docker exec imp-host imp info` shows the new version,
   `https://imps.geoff.cloud/health` answers 200 from the tailnet, and the `imp` dashboard in
   Grafana shows impd's logs.

impd's database lives in `tank/imp`, which has a legacy mountpoint inside imp-host. The host's
`/var/lib/imp` is empty.

## Observe

### Grafana

Grafana is at `http://geoffcloud:30300`, from the tailnet only. The user is `admin`. The password is
a stack output, so this prints a secret to your terminal:

```sh
cd infra
op run --env-file=../.env -- pulumi stack output --stack prod --show-secrets grafanaAdminPassword
```

The dashboards `imp` and `cloudflared` are provisioned from `infra/create-dashboards.ts`. Use
Explore for ad hoc queries.

### Logs (Loki)

Query Loki from Grafana's Explore, with the `Loki` datasource:

| Logs                           | LogQL                                                                     |
| ------------------------------ | ------------------------------------------------------------------------- |
| impd                           | `{job="journal", unit="imp-host.service"}`                                |
| impd errors and warnings       | `{job="journal", unit="imp-host.service"} \|~ "(?i)error\|fail\|warning"` |
| imp's Docker API proxy         | `{job="journal", unit="imp-docker-proxy.service"}`                        |
| k3s, tailscaled, any host unit | `{job="journal", unit="<unit>"}`                                          |
| a pod                          | `{namespace="<namespace>", pod="<pod>"}`                                  |
| cloudflared                    | `{namespace="ingress", container="cloudflared"}`                          |

### Metrics (Prometheus)

Query from Grafana's Explore, or reach Prometheus and Alertmanager directly. Neither has a NodePort,
so forward a port through SSH:

```sh
ssh -L 9090:localhost:9090 root@geoffcloud \
  k3s kubectl -n observability port-forward svc/prometheus-operated 9090
ssh -L 9093:localhost:9093 root@geoffcloud \
  k3s kubectl -n observability port-forward svc/alertmanager-operated 9093
```

Then open `http://localhost:9090` or `http://localhost:9093`.

| Question                       | PromQL                                   |
| ------------------------------ | ---------------------------------------- |
| Does impd answer locally?      | `impd_local_health_up`                   |
| Is the tunnel connected?       | `sum(cloudflared_tunnel_ha_connections)` |
| Which scrape targets are down? | `up == 0`                                |
| What is firing?                | `ALERTS{alertstate="firing"}`            |

### External health check

The Worker `geoff-cloud-health-check` logs each state change. Read its logs in the Cloudflare
dashboard, under Workers.

## Turn on Discord alerts

**PENDING approval.** The Discord receiver is built but off. Turning it on, and sending a test
alert, each need Geoff's approval first.

1. Set the flag and land the change through a PR:

   ```sh
   cd infra
   op run --env-file=../.env -- pulumi config set --stack prod discordAlerts true
   ```

   This adds `geoff-cloud:discordAlerts: 'true'` to `infra/Pulumi.prod.yaml`.

2. `bun run preview` shows the new Secret `observability/alertmanager-discord`. The run fails if
   `ALERT_WEBHOOK_URL` is empty.
3. `bun run up` applies it. Alertmanager then sends every alert to Discord, except the chart's
   always-firing `Watchdog` and its `InfoInhibitor` helper.

To turn it off again, run `op run --env-file=../.env -- pulumi config rm --stack prod discordAlerts`
in `infra/`, and land it the same way. The external health check uses the same webhook either way.

## Rotate a credential

Store the new value in its 1Password item first, then deliver it.

| Credential                                                     | Deliver it with                                                                                       |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| a provider credential: Onidel, Cloudflare, Tailscale, R2 state | nothing: the next run reads the new value through `op run`. Revoke the old one at its source          |
| `ALERT_WEBHOOK_URL`                                            | `bun run up`, which updates the Worker's secret, and Alertmanager's Secret when `discordAlerts` is on |
| `PULUMI_CONFIG_PASSPHRASE`                                     | do not replace the item: the stack's secrets are encrypted with it. Changing it needs a migration     |
| imp's Cloudflare DNS token                                     | `bash scripts/install-imp-dns-token.sh`; impd rereads the file, no restart                            |
| the k3s kubeconfig                                             | `bash scripts/connect-k3s.sh`, then a preview. Read it before any apply                               |
| imp's tailnet key (`tag:imp`)                                  | `bun run up` mints a new one after expiry and writes it to `imp-tailscale-authkey`                    |

**PENDING:** the atc daemon is not deployed. Once it runs, a rotation of its gateway or imp token
needs `systemctl restart atc-daemon` on the host. systemd's `LoadCredential` copies the token files
when the service starts, so a reload rereads only the old copy.

## Reinstall the host

Follow [the reinstall runbook](./runbooks/reinstall-geoffcloud.md). It wipes `vda` only; imp's pool
on `vdb` survives.

## Recover

[The restore runbook](./runbooks/restore-geoff-cloud.md) covers imps, impd's database, the host, the
root disk and the cluster. The atc gateway (PENDING) has
[its own backup and restore runbook](./runbooks/atc-gateway-backup-restore.md).
