# Reference

Lookup tables for geoff.cloud. Every entry matches the code on `main`; PENDING marks parts that
exist in code but are not deployed.

## Root scripts

Run with `bun run <script>` from the repo root. Hooks and CI call these too.

| Script           | What it does                                                                      |
| ---------------- | --------------------------------------------------------------------------------- |
| `preview`        | builds the provider, then `pulumi preview --stack prod` through `op run`          |
| `drift`          | builds the SDK, then `preview --refresh --expect-no-changes`: fails on any change |
| `up`             | builds the provider, then `pulumi up --stack prod` through `op run`               |
| `provider:build` | builds `provider/bin/pulumi-resource-onidel`                                      |
| `provider:check` | `gofmt`, `go vet` and `go test` in `provider/`                                    |
| `sdk:gen`        | regenerates `sdk/onidel/` from the provider binary (`scripts/gen-sdk.sh`)         |
| `sdk:build`      | compiles `sdk/onidel/` to `sdk/onidel/bin/`, which `infra/` imports               |
| `format`         | `oxfmt` and `format-codemod`, writing fixes                                       |
| `format:check`   | the same, check only                                                              |
| `lint`           | `oxlint` with type-aware rules                                                    |
| `lint:fix`       | the same, writing fixes                                                           |
| `typecheck`      | `sdk:build`, then `tsc --noEmit`                                                  |
| `test`           | `bun test`                                                                        |
| `test:scripts`   | the stub test of `install-atc-gateway-credentials.sh` (no host)                   |
| `deadcode`       | `knip`                                                                            |
| `audit`          | `bun audit`                                                                       |
| `build:agents`   | regenerates `AGENTS.md` from `agents/shared.md` and `agents/project.md`           |

Pass Pulumi flags after `--`: `bun run up -- --yes`.

## Checks

| Where                | Runs                                                                                                 |
| -------------------- | ---------------------------------------------------------------------------------------------------- |
| pre-commit           | `oxlint --fix`, `oxfmt`, `format-codemod`, `gofmt` on staged files, then `gitleaks`                  |
| commit-msg           | commitlint (Conventional Commits)                                                                    |
| pre-push             | `format:check`, `lint`, `typecheck`, `test`, `deadcode`, `provider:check`                            |
| CI `checks`          | the `AGENTS.md` drift check, `format:check`, `lint`, `typecheck`, `test`, `test:scripts`, `deadcode` |
| CI `provider`        | `gofmt`, `go vet`, `go test`                                                                         |
| CI `gitleaks`        | gitleaks over the whole history                                                                      |
| `atc-gateway images` | the gateway fixture test on image changes; publishes to GHCR only on a manual run with `push: true`  |

The `main protection` ruleset needs `checks` and `gitleaks` green.

## Stack config

Stack `prod`, file `infra/Pulumi.prod.yaml`, namespace `geoff-cloud`.

| Key             | Values            | Live    | Effect                                                                              |
| --------------- | ----------------- | ------- | ----------------------------------------------------------------------------------- |
| `cluster`       | `managed`, `none` | managed | `managed` deploys the k3s workloads and needs `K3S_KUBECONFIG`. Unset fails the run |
| `hostOnTailnet` | `true`, `false`   | true    | attaches the `edge` firewall to the VM and drops its public SSH rule                |
| `discordAlerts` | `true`, `false`   | unset   | sends in-cluster alerts to Discord; needs `ALERT_WEBHOOK_URL`                       |
| `atcGateway`    | object, see below | unset   | **PENDING.** Deploys the atc gateway                                                |

`atcGateway` fields:

| Field           | Required | Meaning                                                                            |
| --------------- | -------- | ---------------------------------------------------------------------------------- |
| `image`         | yes      | the gateway image, by digest. The fixture stand-in `atc-gateway:2.10.0` is refused |
| `backupImage`   | yes      | the backup image, by digest                                                        |
| `publicURL`     | yes      | the public origin and OAuth issuer                                                 |
| `daemons`       | yes      | the daemons the gateway dials, by name, each with `address` and `daemonID`         |
| `defaultDaemon` | yes      | the daemon a call without one goes to; one of `daemons`                            |
| `stateDir`      | no       | where the state volume mounts; defaults to `$HOME`'s state directory               |

Each entry of `atcGateway.daemons`:

- Its name is a lowercase DNS label of at most 31 characters, starting with a letter, such as
  `geoffcloud` or `home-pc`.
- `address` is the daemon's tailnet `host:port`, such as `100.69.47.33:8415`.
- `daemonID` is the lowercase UUID that `atc daemon id` prints on the daemon's host.
- Its bearer token comes from `ATC_GATEWAY_TOKEN_<NAME>`, the name upper-cased with `-` as `_`, such
  as `ATC_GATEWAY_TOKEN_HOME_PC`.

The Onidel provider reads `onidel:apiKey` (falls back to `ONIDEL_API_KEY`), `onidel:teamId` and
`onidel:endpoint`. This stack sets none of them. See [the provider README](../provider/README.md).

## Stack outputs

Read one with `pulumi stack output --stack prod <name>` from `infra/`, through `op run`. Add
`--show-secrets` for a secret one; it prints the value.

| Output                         | Secret | Holds                                                    |
| ------------------------------ | ------ | -------------------------------------------------------- |
| `grafanaURL`                   | no     | `http://geoffcloud:30300`                                |
| `grafanaAdminPassword`         | yes    | Grafana's `admin` password                               |
| `hostAuthKey`                  | yes    | single-use tailnet key for the host's node (`tag:cloud`) |
| `impHostAuthKey`               | yes    | single-use tailnet key for imp's node on the host        |
| `tunnelToken`                  | yes    | cloudflared's tunnel token                               |
| `geoffcloudIPv4`               | no     | the VM's public IPv4                                     |
| `mcpURL`                       | no     | `https://mcp.geoff.cloud`                                |
| `backupsBucket`                | no     | `geoff-cloud-backups`                                    |
| `onePasswordConnectServiceURL` | no     | **PENDING.** Connect's in-cluster URL                    |
| `atcGatewayServiceURL`         | no     | **PENDING.** The gateway's in-cluster URL                |

## .env

`.env` holds `op://` references only. Each item is in the 1Password vault `cloud`.

| Variable                                                                                                               | Item                              | Used by                                                                           |
| ---------------------------------------------------------------------------------------------------------------------- | --------------------------------- | --------------------------------------------------------------------------------- |
| `ONIDEL_API_KEY`                                                                                                       | `onidel-api`                      | the Onidel provider, `snapshot-geoffcloud.sh`                                     |
| `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`                                                                        | `cloudflare-api`                  | the Cloudflare provider                                                           |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`                                                                           | `r2-pulumi-state`                 | the Pulumi state backend on R2                                                    |
| `PULUMI_BACKEND_URL`                                                                                                   | `r2-pulumi-state`                 | the state bucket's `s3://` URL                                                    |
| `AWS_REGION`                                                                                                           | none: `auto`                      | R2                                                                                |
| `PULUMI_CONFIG_PASSPHRASE`                                                                                             | `pulumi-passphrase`               | Pulumi's secrets provider                                                         |
| `TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET`, `TAILSCALE_TAILNET`                                      | `tailscale-oauth`                 | the Tailscale provider                                                            |
| `ALERT_WEBHOOK_URL`                                                                                                    | `alert-webhook`                   | the health-check Worker; Alertmanager when `discordAlerts` is on                  |
| `K3S_KUBECONFIG`                                                                                                       | `k3s-kubeconfig`                  | the Kubernetes provider                                                           |
| `ONEPASSWORD_CONNECT_CREDENTIALS`                                                                                      | `onepassword-connect-credentials` | **PENDING.** The Connect server's credentials file (JSON), for the Connect Secret |
| `ATC_GATEWAY_TOKEN_GEOFFCLOUD`                                                                                         | `atc-daemon-token`                | **PENDING.** The gateway's bearer for the daemon                                  |
| `ATC_GATEWAY_RESTIC_PASSWORD`                                                                                          | `atc-gateway-restic`              | **PENDING.** The gateway backup's restic password                                 |
| `ATC_GATEWAY_R2_ACCESS_KEY_ID`, `ATC_GATEWAY_R2_SECRET_ACCESS_KEY`, `ATC_GATEWAY_R2_ENDPOINT`, `ATC_GATEWAY_R2_BUCKET` | `r2-atc-gateway-backup`           | **PENDING.** The gateway backup's R2 bucket and key                               |

The gateway's backup builds its restic repository as `s3:<endpoint>/<bucket>/atc-gateway`. With none
of the five backup variables set, the gateway deploys with no backup CronJob; with only some set,
the preview fails and names the missing ones.

Items that `.env` does not reference:

| Item                    | Used by                                                              |
| ----------------------- | -------------------------------------------------------------------- |
| `imp-tailscale-authkey` | imp's scripts. Pulumi writes each new `tag:imp` key into it          |
| `imp-restic`            | imp's backup password, staged on the host at reinstall               |
| `r2-backups`            | imp's backup repository and R2 keys, staged on the host at reinstall |
| `imp-dns-cloudflare`    | imp's DNS token and ACME email (`install-imp-dns-token.sh`)          |

## Hostnames

| Name                                     | Points at                                                           | Owner                 |
| ---------------------------------------- | ------------------------------------------------------------------- | --------------------- |
| `mcp.geoff.cloud`                        | the tunnel → atc on Geoff's PC, port 8414                           | Pulumi                |
| `imps.geoff.cloud`, `*.imps.geoff.cloud` | the host's tailnet IP (DNS only)                                    | impd, never Pulumi    |
| `atc.geoff.cloud`                        | **PENDING.** The tunnel → the atc gateway                           | Pulumi, once deployed |
| `op-connect.imp.internal`                | **PENDING.** Imp guests only: the broker → the host relay → Connect | imp's broker, no DNS  |
| `imp.geoff.cloud`                        | **PENDING.** Reserved for imp's public MCP                          | none yet              |
| `geoffcloud`                             | the host on the tailnet (MagicDNS)                                  | Tailscale             |
| `imp-geoffcloud`                         | imp's own tailnet node on the host                                  | Tailscale             |

## Ports

| Port      | Where                               | Reachable from                                     | Service                          |
| --------- | ----------------------------------- | -------------------------------------------------- | -------------------------------- |
| udp 41641 | `geoffcloud`, public                | the internet                                       | Tailscale direct connections     |
| tcp 22    | `geoffcloud`                        | tailnet admins (Tailscale SSH)                     | SSH                              |
| tcp 6443  | `geoffcloud`                        | the tailnet                                        | the k3s API                      |
| tcp 30300 | `geoffcloud`, tailnet address only  | the tailnet                                        | Grafana (NodePort)               |
| tcp 7070  | host loopback, and `imp-geoffcloud` | the host; tailnet members; `tag:imp` nodes         | impd's API and `/health`         |
| tcp 8414  | Geoff's PC (`home-pc`)              | tailnet members; `tag:cloud`                       | `atc mcp --http`                 |
| tcp 8415  | `geoffcloud`, tailnet address       | k3s pods only (`inet cloud_host`)                  | the atc daemon (**PENDING**)     |
| tcp 18081 | `geoffcloud`, docker0 address       | imp-host's docker0 subnet only (`inet cloud_host`) | the Connect relay (**PENDING**)  |
| tcp 2000  | cloudflared pods                    | the cluster                                        | cloudflared metrics and `/ready` |
| tcp 3100  | `loki.observability.svc`            | the cluster                                        | Loki                             |

## Host paths

On `geoffcloud`.

| Path                                          | Holds                                                          |
| --------------------------------------------- | -------------------------------------------------------------- |
| `/var/lib/tailscale/authkey`                  | the host's tailnet join key, staged at install                 |
| `/var/lib/imp-host/secrets/tailscale-authkey` | imp's tailnet join key                                         |
| `/var/lib/imp-host/secrets/imp-host.env`      | imp-host's environment: backup repository, R2 keys, ACME email |
| `/var/lib/imp-host/secrets/backup-password`   | imp's restic password                                          |
| `/var/lib/imp-host/secrets/dns-api-token`     | imp's Cloudflare DNS token                                     |
| `/var/lib/node-exporter/textfile/`            | `impd_local_health.prom`, read by node-exporter                |
| `/etc/rancher/k3s/k3s.yaml`                   | the k3s kubeconfig (server `127.0.0.1`)                        |
| `/etc/k3s-resolv.conf`                        | DNS for pods: 1.1.1.1 and 9.9.9.9                              |
| `/root/imp-db-backups/`                       | copies of impd's database from before imp upgrades             |
| `tank/imp` (ZFS)                              | impd's state; a legacy mount inside imp-host only              |
| `/var/lib/atc-daemon-secrets/`                | the atc daemon's token files: `gateway-token`, `imp-token`     |
| `/var/lib/atc-daemon/`                        | **PENDING.** The atc daemon's home                             |

Never touch `/dev/vdb`: it holds the pool `tank`.

## Alert rules

The PrometheusRule `geoff-cloud-alerts`, from `infra/build-alert-rules.ts`.

| Alert                      | Fires when                                                                                                    | Severity |
| -------------------------- | ------------------------------------------------------------------------------------------------------------- | -------- |
| `ImpdLocalHealthDown`      | `impd_local_health_up == 0` for 2 minutes                                                                     | critical |
| `ImpdLocalHealthStale`     | the probe is over 5 minutes old, or its metric is absent, for 2 minutes                                       | warning  |
| `TargetDown`               | any scrape target has `up == 0` for 5 minutes                                                                 | warning  |
| `CloudflaredNoConnections` | both cloudflared pods hold 0 connections, the metric is absent, or no cloudflared target is up, for 5 minutes | critical |
| `ATCDaemonUnreachable`     | **PENDING.** the TCP probe of a daemon in `atcGateway.daemons` fails, or its metric is absent, for 5 minutes  | critical |

- `TargetDown` is per target, and replaces the chart's ratio-based rule of the same name. One
  cloudflared pod down shows as `TargetDown`; the tunnel serves while either pod is connected.
- Alertmanager drops the chart's always-firing `Watchdog` and its `InfoInhibitor` helper.
- `ATCDaemonUnreachable` and its probe exist only while `atcGateway` is set. The probe is the
  blackbox exporter (`atc-daemon-probe` in `observability`): a TCP connect from a pod to each daemon
  every 30 seconds, on the gateway's own path to it, and one rule per daemon.

## scripts/

| Script                                    | What it does                                                                                                                                                                 |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `snapshot-geoffcloud.sh <name>`           | takes an Onidel snapshot of `vda` and lists snapshots. Run through `op run`                                                                                                  |
| `connect-k3s.sh [host]`                   | stores the host's kubeconfig in `k3s-kubeconfig` and references it in `.env`                                                                                                 |
| `install-imp-dns-token.sh`                | installs imp's DNS token and ACME email on the host; also the rotation path                                                                                                  |
| `gen-sdk.sh`                              | `sdk:gen`: regenerates the Onidel SDK                                                                                                                                        |
| `build-agents-md.sh`                      | `build:agents`: concatenates the agent rules partials                                                                                                                        |
| `check-atc-gateway-readiness.sh [host]`   | **PENDING.** Readiness checks for the atc gateway; once it is deployed, they run a temporary probe pod                                                                       |
| `install-atc-gateway-credentials.sh`      | creates the impd secret `glm`, the impd token `atc-cloud` and the daemon bearer; skips each one that exists, the saved impd token only after it authenticates as `atc-cloud` |
| `copy-impd-db.sh <label>`                 | takes a consistent copy of impd's database, with `COPY-INFO`, into `/root/imp-db-backups/`                                                                                   |
| `fetch-atc-release.sh <dir>`              | downloads and checksums the pinned atc release for the gateway image                                                                                                         |
| `test-atc-gateway-fixture.sh`             | the gateway image fixture test, locally in Docker                                                                                                                            |
| `test-install-atc-gateway-credentials.sh` | stub test of the credential script's rerun check on the saved impd token; no host                                                                                            |
| `check-agent-image.sh --imp <name>`       | checks the agent image in a running imp (or `--docker <image>`): login state, a gitleaks scan, each pinned version                                                           |

## Repo layout

| Path          | Holds                                                                   |
| ------------- | ----------------------------------------------------------------------- |
| `infra/`      | the Pulumi program (TypeScript, Bun runtime)                            |
| `provider/`   | the partial Onidel Pulumi provider (Go)                                 |
| `sdk/onidel/` | its generated TypeScript SDK. Never edit by hand: run `bun run sdk:gen` |
| `workers/`    | the health-check Worker, bundled by `infra/` at deploy time             |
| `nixos/`      | the host flake: `hosts/geoffcloud`, `modules/`, `checks/`               |
| `deploy/`     | the atc gateway's images and restore Job (PENDING)                      |
| `scripts/`    | repo and host tooling                                                   |
| `docs/`       | these pages, `runbooks/` and `plans/`                                   |
| `agents/`     | the partials that build `AGENTS.md`                                     |
