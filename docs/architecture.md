# Architecture

`geoff.cloud` is Geoff's general-purpose private cloud: hosts on the tailnet, defined in this repo,
that run whatever he wants to run. The platform layer is the same for every workload: a NixOS host,
a single-node k3s cluster, Pulumi for every cloud resource, and the tailnet as the private network.
Workloads come and go on top of it.

This page gives the shape, the decisions behind it and the open risks. The
[README](../README.md#status) says what is live and what is pending.

## First workload: an agent platform

The first thing the cloud hosts is a platform for isolated coding agents. It shapes some early
choices, such as KVM on the host and the first public hostname, but it is one tenant among future
ones:

1. [imp](https://github.com/zgeoff/imp) isolates agents in Firecracker microVMs on the host.
2. [atc](https://github.com/zgeoff/atc) manages agent sessions and uses imp as a backend.
3. atc's MCP endpoint is public at `mcp.geoff.cloud`, behind atc's own OAuth. The edge sits on the
   cloud host and reaches atc on Geoff's PC over the tailnet.
4. An assistant (ChatGPT, Claude) connects to that MCP, so Geoff can start agents from it.

**PENDING:** the atc gateway moves the public origin to `atc.geoff.cloud`, in k3s, and dials an atc
daemon on `geoffcloud`. [The gateway plan](./plans/atc-gateway.md) holds its design and state.

## Shape

```text
 ChatGPT / Claude.ai ──HTTPS──▶ Cloudflare edge (mcp.geoff.cloud)
                                     │ Cloudflare Tunnel (outbound from the host)
                                     ▼
 ┌──────────── geoffcloud (Onidel, NixOS) ──────────────────────────────────────┐
 │  k3s (single node)                                                           │
 │   ├─ cloudflared          public ingress (today: mcp.geoff.cloud → PC)       │
 │   ├─ observability        Prometheus, Alertmanager, Loki, Grafana, Alloy     │
 │   ├─ system               coredns, local-path, metrics-server                │
 │   └─ future workloads     anything else Geoff runs                           │
 │                                                                              │
 │  imp-host container (Docker) — outside k3s                                   │
 │   └─ impd + firecracker ×N   ZFS pool on vdb   own tailnet node (tag:imp)    │
 │                                                                              │
 │  host: tailscaled (tag:cloud)   nftables: inet nixos-fw, imp-forward, k3s    │
 └──────────────────────────────────────────────────────────────────────────────┘
                                     │ tailnet (WireGuard)
                                     ▼
 Geoff's PC: atc daemon (unix socket) ◀── atc mcp --http on <tailnet IP>:8414
```

## Host: Onidel VM, NixOS

- **VM `geoffcloud`:** Onidel, Melbourne. 8 vCPU (AMD EPYC 7513), 31 GiB RAM, nested KVM
  (`/dev/kvm`). Root disk `vda` 240 GB. Block volume `vdb` 200 GB NVMe, owned by imp's ZFS pool
  `tank`.
- **OS:** NixOS. The whole host is one flake in `nixos/`, with atomic rollback. NixOS has modules
  for every part (ZFS, Docker, k3s, Tailscale), and imp ships one. Talos was ruled out: it hosts
  only Kubernetes, and imp needs a mutable host with Docker, KVM and ZFS.
- **Install:** `nixos-anywhere` over SSH, with `disko` for `vda` only. `vdb` is never in the disko
  layout; NixOS imports imp's existing pool. See
  [the reinstall runbook](./runbooks/reinstall-geoffcloud.md).
- **Changes:** a `nixos-rebuild switch` from a `nixos/nix` container, run by hand. Pulumi does not
  drive the host. See [Workflows](./workflows.md#switch-the-host).

## Workloads: imp on the host, the rest in k3s

- **imp** runs as imp ships it: one `imp-host` container on the host's Docker daemon, outside k3s,
  set up by imp's NixOS module (`services.imp`). imp schedules its own microVMs, so Kubernetes adds
  nothing for it.
- **k3s** runs every other workload, single node. It is chosen for the tooling: Helm charts,
  operators and kube-prometheus-stack. It is not chosen for scheduling, because a single node needs
  none. A second node, or a move to bare metal, joins the same cluster.
- **Deploys:** Pulumi's Kubernetes provider applies the k3s workloads through the k3s API on the
  tailnet. One `pulumi preview` covers cloud resources and cluster resources.

## Public ingress: Cloudflare Tunnel, the app owns OAuth

- `cloudflared` runs in k3s (two replicas) and holds an outbound-only tunnel, `geoff-cloud`. The
  host opens no inbound port for it. The routes live in Cloudflare, not in the cluster.
- The tunnel routes every path on `mcp.geoff.cloud` over the tailnet to Geoff's PC, where
  `atc mcp --http` binds to the PC's tailnet address on port 8414. The hop is plain HTTP inside
  WireGuard. Any other hostname gets a 404.
- **Auth is atc's.** atc runs its own OAuth 2.1 server. Cloudflare Access must not front the
  hostname, because the OAuth endpoints (`/.well-known/*`, `/authorize`, `/token`, `/register`) must
  stay reachable without a login.
- The route sends `Host: mcp.geoff.cloud`, because atc rejects unknown hosts to block DNS rebinding.
- The route targets the PC's tailnet IP, not its MagicDNS name: CoreDNS in k3s does not forward to
  Tailscale's resolver.
- The zone redirects plain HTTP to HTTPS on every hostname. The redirect cannot protect a token in a
  plain HTTP request, because that first request already carries it. Clients must use `https://`
  URLs directly.
- atc documents the PC side in its exposure guide. This repo does not manage the PC.

## Tailnet

Pulumi owns the whole tailnet policy file (`infra/tailnet-policy.ts`).

| Tag         | Holder                                                    | May reach                          |
| ----------- | --------------------------------------------------------- | ---------------------------------- |
| `tag:cloud` | the host's own tailscaled, and so every pod's egress      | Geoff's PC (`home-pc`) on tcp 8414 |
| `tag:imp`   | impd nodes: `imp-geoffcloud`, and imp's dev and e2e nodes | other `tag:imp` nodes on tcp 7070  |

- Members reach every device on any port.
- Admins SSH to `tag:cloud` hosts as root or a non-root user, with no browser check, so scripts run
  unattended.
- MagicDNS stays on.
- Tailnet SSH replaces public SSH. Onidel's cloud firewall closes port 22 from the internet.

**CAUTION:** Pulumi's Tailscale `Acl` resource replaces the whole policy file. A rule missing from
`infra/tailnet-policy.ts` is deleted on the next apply. Geoff reviews every preview that changes it.

## Firewalls

- **Outside the VM:** Onidel's cloud firewall group `edge` allows Tailscale's UDP port (41641) and
  ICMP, and nothing else. It is attached, and public SSH is gone (`hostOnTailnet: true`).
- **On the host:** the NixOS firewall in its own table, `inet nixos-fw`. It allows only UDP 41641 in
  public, trusts `tailscale0`, `cni0` and `flannel.1`, and filters forwarded traffic, so no public
  packet reaches a pod or a NodePort.
- imp's module adds the table `inet imp-forward`, which stops imps from reaching the k3s pod and
  service ranges. imp's egress table, `inet imp_egress`, lives inside the imp-host container. k3s
  and Docker add their own tables.
- `networking.nftables.flushRuleset` stays off, because it would flush every other table on reload.

## Infrastructure as code: Pulumi in TypeScript, on Bun

One Pulumi program, `infra/`, owns every cloud resource:

| Provider             | Manages                                                                         |
| -------------------- | ------------------------------------------------------------------------------- |
| Onidel (ours, Go)    | the VM, the `edge` firewall group and its rules                                 |
| `@pulumi/cloudflare` | the tunnel and its routes, DNS, the HTTPS redirect, the health-check Worker, R2 |
| `@pulumi/tailscale`  | the policy file and the auth keys (`TailnetKey`)                                |
| `@pulumi/kubernetes` | the k3s workloads                                                               |
| `@pulumi/command`    | one local command: copying imp's tailnet key into 1Password                     |

- **Onidel provider:** no Terraform or Pulumi provider exists, so this repo has a partial one in Go,
  in `provider/`. Pulumi generates its TypeScript SDK into `sdk/onidel/`. See
  [its README](../provider/README.md).
- **The VM is protected.** It was made by hand and imported. Almost every input replaces it, so
  `protect` and `retainOnDelete` guard it.
- **Block volumes:** Onidel's API has no volume calls. `vdb` is a manual step.
- **Host config:** the NixOS flake, not Pulumi.
- **State:** Pulumi's S3 backend on Cloudflare R2, with a passphrase secrets provider.
- **impd's DNS records** (`imps.geoff.cloud`, `*.imps.geoff.cloud`,
  `_acme-challenge.imps.geoff.cloud`) belong to impd. Pulumi never declares them.

## Secrets

Every deployment input lives in the 1Password vault `cloud`. The committed `.env` holds only `op://`
references, resolved with `op run`. Three kinds of secret live elsewhere, and 1Password cannot
restore them:

- Secrets that Pulumi generates, such as Grafana's admin password, exist only in Pulumi state,
  encrypted, in R2.
- impd's own secrets live in its dataset `tank/imp` on `vdb`: the root `token`, the broker CA in
  `broker/`, its TLS files in `tls/` and the secret values in `secrets/`. impd's database holds its
  tokens and secret names.
- Host-side secrets sit in root-only files under `/var/lib/` on `geoffcloud`, staged by the
  reinstall or by a script in `scripts/`.

[The restore runbook](./runbooks/restore-geoff-cloud.md#2-roll-impds-database-back) says what a
database restore loses. gitleaks runs in the pre-commit hook and in CI. See
[the reference](./reference.md#env) for each item.

## Observability

- **Self-hosted** in k3s, in the namespace `observability`: kube-prometheus-stack (Prometheus,
  Alertmanager, Grafana, node-exporter), Loki and Alloy. Metrics and logs keep 30 days.
- **Logs:** Alloy ships every pod's logs and the host's journal to Loki. impd logs to the journal
  through `imp-host.service`, so its logs are in Loki too. The gateway's OAuth approval lines
  (PENDING) are dropped before Loki.
- **impd health:** a host timer probes impd's `/health` on loopback every minute, and writes the
  result for node-exporter's textfile collector.
- **Grafana** is a NodePort (30300) that binds to the tailnet range only: `http://geoffcloud:30300`.
  It has two provisioned dashboards, `imp` and `cloudflared`.
- **External check:** monitoring on the same host cannot report that the host is down. The Worker
  `geoff-cloud-health-check` runs every 5 minutes from Cloudflare's edge and probes
  `mcp.geoff.cloud`. A 530 means the tunnel or the host is down; a 502 or 504 means the PC or atc is
  down. It keeps the last state in R2, and on a change it logs and posts to the alert webhook.

## Alerting

Prometheus evaluates the PrometheusRule `geoff-cloud-alerts` and sends to Alertmanager. A missing
metric alerts; it never reads as healthy. The chart's default rules also run.
[The reference](./reference.md#alert-rules) lists the rules.

**The Discord receiver is gated off.** With the stack config `discordAlerts` unset or false,
Alertmanager routes every alert to a null receiver and sends nothing. Firing alerts still show in
Prometheus and Alertmanager. Grafana does no alerting.

## Backups

| Data                        | Backup                                                                         |
| --------------------------- | ------------------------------------------------------------------------------ |
| imps                        | impd's own restic backups to R2, `geoff-cloud-backups/imp/geoffcloud`          |
| impd's database             | a copy on the host before each imp upgrade, in `/root/imp-db-backups/`         |
| the root disk (`vda`)       | an Onidel snapshot before a risky change (`scripts/snapshot-geoffcloud.sh`)    |
| k3s objects                 | none: Pulumi recreates them. Loki's and Prometheus's volumes are not backed up |
| Pulumi state, secrets       | R2 holds the state; 1Password holds the deployment inputs                      |
| atc gateway state (PENDING) | restic to R2; see [its runbook](./runbooks/atc-gateway-backup-restore.md)      |

## RAM budget

| Consumer            | RAM          |
| ------------------- | ------------ |
| imp guests and impd | 20 GiB       |
| ZFS ARC (imp pool)  | about 3 GiB  |
| NixOS host          | about 1 GiB  |
| k3s                 | about 1 GiB  |
| Observability       | about 1 GiB  |
| cloudflared         | about 50 MiB |
| Spare               | about 5 GiB  |

## Risks and open questions

- **Secure Boot.** The VM boots UEFI with Secure Boot on. Kernel lockdown blocks the unsigned kexec
  that `nixos-anywhere` uses, so Secure Boot goes off in the Onidel panel for an install.
  `lanzaboote` could turn it back on with our own keys.
- **ZFS and the kernel.** The ZFS module must support the host's kernel, which can hold a NixOS
  upgrade back.
- **The ingress hop to the PC** needs the PC online and `atc mcp --http` running. That is accepted
  until the atc gateway and the cloud daemon replace it.
- **The Pulumi `Acl` takeover:** see the caution under Tailnet.
- **Plain state on the root disk.** Onidel snapshots hold the k3s datastore (tunnel token, Grafana
  password) in plain form, behind the Onidel account.
