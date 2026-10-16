# Workflows

Common tasks on geoff.cloud. Each change lands through a squash PR to `main`; run live changes from
a clean checkout of `main`.

**CAUTION:** No live change without a preview first. A change that costs money, deletes data or
cannot be undone needs the owner's approval of its exact effect.

## Change infrastructure

1. Edit `infra/`, and open a PR.
2. Preview it. The preview changes nothing:

   ```sh
   bun run sdk:build
   bun run preview
   ```

   Read every replace and delete. If the preview changes the tailnet policy, the owner reviews the
   diff first: Pulumi replaces the whole policy file.

3. Merge it. Once CI passes on `main`, the `Deploy prod` workflow checks drift from the deployed
   revision, previews, applies and checks drift again, unless its guard holds the plan.
   [The prod apply job](./prod-apply.md) covers reading its run and answering a held one.
4. Link the run on the PR or issue. Its log holds both drift results.

Pass Pulumi flags after `--`, such as `bun run preview -- --diff`.

### Apply by hand

Apply by hand only for what the job cannot do, such as a first apply before the job is set up.

**CAUTION:** Check that no `Deploy prod` run is in progress first
(`gh run list --workflow deploy-prod.yml --status in_progress`). Two applies at once race on the
stack.

1. Check the baseline from a clean checkout of the revision at the tag `deployed/prod`, or of the
   last revision applied by hand:

   ```sh
   bun run drift
   ```

   It exits non-zero on any change, so it expects 0 changes only against the deployed code. Record
   the revision and the result. Resolve drift before you go on.

2. From a clean current `main`, preview against the live state:

   ```sh
   bun run preview -- --refresh
   ```

   Expect exactly the intended changes, reviewed on their PRs, and nothing else.

3. Apply:

   ```sh
   bun run up
   ```

4. Run `bun run drift` again, and expect 0 changes. Record both drift results on the PR or issue.
5. Once `deployed/prod` exists, move it to the revision you applied, so the job's next run starts
   from it:

   ```sh
   git tag -f deployed/prod <revision>
   git push --force origin refs/tags/deployed/prod
   ```

### Change stack config

Stack config lives in `infra/Pulumi.prod.yaml`, under the namespace `geoff-cloud`. Set a key from
`infra/`, through `op run` so Pulumi can decrypt the stack:

```sh
cd infra
op run --env-file=../.env -- pulumi config set --stack prod <key> <value>
```

Land the YAML change through a PR, which the apply job applies after the merge.
`infra/Pulumi.prod.yaml` holds the keys, and the program's input loaders describe each one.

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
2. It refuses a commit that no green run of the NixOS checks covers, as
   [Check the host before a switch](#check-the-host-before-a-switch) describes. `--build-only` skips
   this gate, because it reaches no host.
3. It refuses a commit whose atc daemon pin is another atc major release than a running atc gateway
   pod's image, or that finds no gateway pod, because atc breaks the daemon protocol only in a major
   release and the daemon handshake does not catch the break. It checks again before the activation.
   For an atc major bump, publish the atc-gateway images and merge the pull request that pins their
   digests, let the `Deploy prod` workflow roll it out, then switch. `--build-only` skips this gate
   too.
4. It refuses a commit whose impd, the imp-host image's release, is a major release that a running
   nixie pod's `@zgeoff/imp-client` refuses, or that finds no nixie pod, because nixie then retries
   its start without end while every host check passes. It reads the client's version from the
   `bun.lock` of the pod's nixie release on GitHub, and accepts impd 2 beside a 1.x client from
   nixie 0.28.0 on, as nixie itself does. It checks again before the activation. For an impd major
   bump, deploy a nixie release whose client speaks the new major first. `--build-only` skips this
   gate too.
5. It builds a `git archive` snapshot of that commit with `nix build --no-link`, so untracked files
   and edits made during the run never reach the build. A failed build stops the script, and nothing
   reaches the host.
6. It copies the built store path to the host with `nix copy`, sets the system profile to it and
   runs its `switch-to-configuration switch` under `systemd-run`, as `nixos-rebuild` does. The flake
   is not evaluated again.
7. It fails unless the host's `/run/current-system` is the built path, then prints
   `systemctl --failed`, which should list nothing.
8. It asks nixie's `/health/ready` for its report, up to 30 times 10 s apart, and fails with each
   part that is not ready and nixie's reason for it, since a host that switches cleanly can still
   leave nixie unable to start.

`bash scripts/test-switch-geoffcloud.sh` (part of `bun run test:scripts`) checks the gates with stub
`gh`, `docker` and `ssh`. After a switch, `ssh root@geoffcloud k3s kubectl get nodes` should show
the node `Ready`.

Before a risky host change, take an Onidel snapshot of the root disk:

```sh
op run --env-file=.env -- bun run onidel:snapshot pre-<change>
```

The flake also has checks: one for each of its modules and one for the impd database tools,
`test-utils` for the helpers and the stand-in impd they share, and `impd-restore` and
`impd-restore-seams`, NixOS VM rehearsals of `restore-impd-db` on one shared machine that need KVM:
`impd-restore-seams` holds the errors only a stand-in `systemctl` or `cmp` reaches.
`bun run test:nixos` builds every check the flake declares in a `nixos/nix` container, from a
snapshot of the working tree's tracked and unignored files. Its Nix store is the Docker volume
`cloud-nixos-checks-store`, never the switch's `geoffcloud-nix-store`.
`bun run test:nixos atc-daemon` builds one check.

### Check the host before a switch

The NixOS checks gate the switch, not the merge, so a pull request that changes `nixos/` merges
without them. The `NixOS checks` workflow builds them on `main` every night, and skips the build
when an earlier green run covers the commit. A green scheduled or dispatched run on `main` covers
every later commit that changes no input of the checks: `nixos/`, the scripts and test helpers the
checks read or run, the scripts that decide when they run, `.bun-version` and the workflow. An app's
pull request that changes `nixos/`, such as a release bump, runs the checks before it merges; a
person's pull request skips them.

To switch before the nightly run covers the commit:

1. Start a run on `main`:

   ```sh
   gh workflow run nixos-checks.yml --ref main
   ```

2. Find the run's id, the first column of the newest `workflow_dispatch` row, and wait for it:

   ```sh
   gh run list --workflow nixos-checks.yml --branch main --limit 3
   gh run watch <run_id> --exit-status
   ```

   Expect exit 0. A failed run means the commit breaks a check: fix it in a PR rather than
   switching.

3. Run `bash scripts/switch-geoffcloud.sh`. Expect its first line to be `== checked by <run url>`.

`bash scripts/find-nixos-check-run.sh <commit>` prints the run that covers a commit, or nothing.

## Upgrade imp

imp is pinned in two places, and both move together:

| Pin                  | File                                                                                  |
| -------------------- | ------------------------------------------------------------------------------------- |
| imp's NixOS module   | the `imp` input in `nixos/flake.nix`, and `nixos/flake.lock`                          |
| the `imp-host` image | `services.imp.image` in `nixos/hosts/geoffcloud/configuration.nix`, by tag and digest |

1. Update both pins in a PR. Read imp's release notes for migrations and new host settings. The
   [release check](./release-check.md) opens this PR for each new imp release, with the imp-base pin
   of the agent image.
2. Copy impd's database. Never tar the live files:

   ```sh
   bash scripts/copy-impd-db.sh imp-<old version>-pre-<new version>
   ```

   The copy and its `COPY-INFO` land in `/root/imp-db-backups/`.
   [The restore runbook](./restore-geoff-cloud.md#2-roll-impds-database-back) puts a copy back.

3. [Switch the host](#switch-the-host). The switch restarts impd.
4. Check: `ssh root@geoffcloud docker exec imp-host impz info` shows the new version,
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

The dashboards `imp` and `cloudflared` are provisioned from
`infra/observability/create-dashboards.ts`. Use Explore for ad hoc queries.

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

## Turn Discord alerts on or off

Discord alerts are on in `prod`. Changing the flag, or sending a test alert, needs the owner's
approval first.

1. Set the flag and land the change through a PR:

   ```sh
   cd infra
   op run --env-file=../.env -- pulumi config set --stack prod discordAlerts true
   ```

   This adds `geoff-cloud:discordAlerts: 'true'` to `infra/Pulumi.prod.yaml`.

2. `bun run preview` shows the new Secret `observability/alertmanager-discord`. The run fails if
   `ALERT_WEBHOOK_URL` is empty.
3. The merge applies it through the apply job. Alertmanager then sends every alert to Discord,
   except the chart's always-firing `Watchdog` and its `InfoInhibitor` helper.

To turn it off again, run `op run --env-file=../.env -- pulumi config rm --stack prod discordAlerts`
in `infra/`, and land it the same way. The external health check uses the same webhook either way.

## Rotate a credential

Store the new value in its 1Password item first, then deliver it. An item `.env` references has a
copy in the vault `cloud-deploy` for the apply job: update both.

| Credential                                                     | Deliver it with                                                                                       |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| a provider credential: Onidel, Cloudflare, Tailscale, R2 state | nothing: the next run reads the new value through `op run`. Revoke the old one at its source          |
| `ALERT_WEBHOOK_URL`                                            | `bun run up`, which updates the Worker's secret, and Alertmanager's Secret when `discordAlerts` is on |
| `PULUMI_CONFIG_PASSPHRASE`                                     | do not replace the item: the stack's secrets are encrypted with it. Changing it needs a migration     |
| imp's Cloudflare DNS token                                     | `bash scripts/install-imp-dns-token.sh`; impd rereads the file, no restart                            |
| the k3s kubeconfig                                             | `bash scripts/connect-k3s.sh`, then a preview. Read it before any apply                               |
| `GHCR_PULL_TOKEN`                                              | the apply bracket in [the GHCR pull token](./ghcr-pull-token.md#rotate-the-token), then a pull check  |
| imp's tailnet key (`tag:imp`)                                  | `bun run up` mints a new one after expiry and writes it to `imp-tailscale-authkey`                    |

A rotation of the atc daemon's gateway or imp token needs `systemctl restart atc-daemon` on the
host. systemd's `LoadCredential` copies the token files when the service starts, so a reload rereads
only the old copy.

## Reinstall the host

Follow [the reinstall runbook](./reinstall-geoffcloud.md). It wipes `vda` only; imp's pool on `vdb`
survives.

## Recover

[The restore runbook](./restore-geoff-cloud.md) covers imps, impd's database, the host, the root
disk and the cluster. The atc gateway has
[its own backup and restore runbook](./atc-gateway-backup-restore.md).
