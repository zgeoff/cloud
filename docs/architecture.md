# Architecture

`geoff.cloud` is Geoff's general-purpose private cloud: hosts on the tailnet, defined in this repo,
that run whatever he wants to run. The platform layer is the same for every workload: a NixOS host,
a single-node k3s cluster, Pulumi for every cloud resource, and the tailnet as the private network.
Workloads come and go on top of it.

This page gives the shape, the decisions and the open questions. It is the target design; the
[tracking issue](https://github.com/zgeoff/cloud/issues/1) shows what exists today.

## First workload: an agent platform

The first thing the cloud hosts is a platform for isolated coding agents. It shapes some early
choices, such as KVM on the host and the first public hostname, but it is one tenant among future
ones:

1. [imp](https://github.com/zgeoff/imp) isolates agents in Firecracker microVMs on the host.
2. [atc](https://github.com/zgeoff/atc) manages agent sessions and uses imp as a backend, in place
   of a local PTY.
3. atc's MCP endpoint is public at `mcp.geoff.cloud`, behind atc's own OAuth. The edge sits on the
   cloud host and reaches atc on Geoff's PC over the tailnet.
4. An OpenAI client connects to that MCP, so Geoff can start isolated agents on his own cloud from
   his assistant and drive the sessions from his own machine.

## Shape

```text
 ChatGPT / Claude.ai ──HTTPS──▶ Cloudflare edge (mcp.geoff.cloud)
                                     │ Cloudflare Tunnel (outbound from the host)
                                     ▼
 ┌──────────── geoffcloud (Onidel, NixOS) ──────────────────────────────────────┐
 │  k3s (single node)                                                           │
 │   ├─ cloudflared          public ingress (today: mcp.geoff.cloud → PC)       │
 │   ├─ observability        Prometheus, Loki, Grafana, Alloy                   │
 │   ├─ system               coredns, local-path, metrics-server                │
 │   └─ future workloads     anything else Geoff runs                           │
 │                                                                              │
 │  imp-host container (Docker, privileged) — outside k3s                       │
 │   └─ impd + firecracker ×N   ZFS pool on vdb   own tailnet node (tag:imp)    │
 │                                                                              │
 │  host: tailscaled (tag:cloud)   nftables table inet cloud_host               │
 └──────────────────────────────────────────────────────────────────────────────┘
                                     │ tailnet (WireGuard)
                                     ▼
 Geoff's PC: atc daemon (unix socket) ◀── atc mcp --http 127.0.0.1:8414 ◀── tailscale serve
```

## Decisions

### Host: Onidel VM, NixOS

- **VM `geoffcloud`:** Onidel, Melbourne. 8 vCPU (AMD EPYC 7513), 31 GiB RAM, nested KVM
  (`/dev/kvm`). Root disk `vda` 240 GB. Block volume `vdb` 200 GB NVMe, owned by imp's ZFS pool.
- **OS:** NixOS. The whole host is one flake in this repo, with atomic rollback. Ubuntu was the fast
  path because imp's bootstrap targets it; NixOS wins on reproducibility and on having modules for
  every part (ZFS, Docker, k3s, Tailscale). Talos was ruled out: it hosts only Kubernetes, and imp
  needs a mutable host with Docker, KVM and ZFS.
- **Install:** `nixos-anywhere` over SSH, with `disko` for `vda` only. The runbook is
  [reinstall-geoffcloud.md](./runbooks/reinstall-geoffcloud.md). `vdb` is never in the disko layout;
  NixOS imports imp's existing pool.
- **Kernel:** pinned to a version that the ZFS module supports.

### Workloads: imp on the host, the rest in k3s

- **imp** runs as imp ships it: one privileged `imp-host` container on the host's Docker daemon,
  outside k3s. imp is itself a compute platform. It schedules its own microVMs, so Kubernetes adds
  nothing for it. imp provides `nixosModules.imp` from its flake for NixOS hosts, and keeps
  `bootstrap.sh` for Ubuntu and Debian.
- **k3s** runs every other workload, single node. It is chosen for the tooling: Helm charts,
  operators and kube-prometheus-stack. It is not chosen for scheduling, because a single node needs
  none. A second node, or a move to bare metal, joins the same cluster.
- **Deploys:** Pulumi's Kubernetes provider applies the k3s workloads, through the k3s API on the
  tailnet. One tool and one `pulumi preview` cover cloud resources and cluster resources. Flux is
  the alternative if pull-based GitOps becomes worth its cost.

### Public ingress: Cloudflare Tunnel, atc owns OAuth

- `cloudflared` runs in k3s and holds an outbound-only tunnel. The host opens no inbound port for
  it.
- The tunnel routes every path on `mcp.geoff.cloud` over the tailnet to Geoff's PC. On the PC,
  `tailscale serve` forwards to `atc mcp --http` on `127.0.0.1:8414`.
- **Auth is atc's.** atc runs its own OAuth 2.1 server: protected-resource metadata, CIMD and DCR,
  PKCE S256, RFC 8707 resource binding, RFC 9207 `iss`, per-tool scopes, and local revocation.
  Cloudflare Access must not front the hostname, because the OAuth endpoints (`/.well-known/*`,
  `/authorize`, `/token`, `/register`) must stay reachable without a login.
- The route passes `Host: mcp.geoff.cloud` (atc rejects unknown hosts to block DNS rebinding) and
  does not buffer responses, so SSE works.
- The route targets the PC's tailnet IP, not its MagicDNS name: CoreDNS in k3s does not forward to
  Tailscale's resolver. `tailscale serve` on the PC terminates TLS with the PC's `*.ts.net`
  certificate, so the route sets `originRequest.originServerName: <pc>.<tailnet>.ts.net` for SNI and
  certificate checks. The tailnet needs HTTPS certificates turned on for that.
- atc documents the PC side (`tailscale serve` and
  `atc mcp --http --public-url https://mcp.geoff.cloud`) in its exposure guide. The PC is not
  managed from this repo.

### Tailnet

| Tag         | Holder                                                | May reach                                     |
| ----------- | ----------------------------------------------------- | --------------------------------------------- |
| `tag:cloud` | the host's own tailscaled, and the cloudflared egress | Geoff's PC on the `tailscale serve` port only |
| `tag:imp`   | impd nodes (host, dev, e2e)                           | nothing: imp's isolation goal                 |

- Members reach `tag:cloud` (SSH, the k3s API, Grafana) and `tag:imp` on any port.
- MagicDNS stays on. imp prints `<node>.<tailnet>.ts.net` URLs.
- Tailnet SSH replaces public SSH. Onidel's cloud firewall closes port 22 from the internet.

**CAUTION:** Pulumi's Tailscale `Acl` resource replaces the whole policy file. The first apply must
start from an import of the live policy, with the diff reviewed by Geoff. Existing rules for
`tag:imp`, Geoff's devices and anything else on the tailnet must survive it.

### Firewalls

- **Outside the VM:** Onidel's cloud firewall allows Tailscale's UDP port (41641) and ICMP, and
  nothing else. It needs no host cooperation, so it cannot conflict with imp or k3s.
- **Onidel edge firewall:** the group `edge` allows SSH, Tailscale UDP and ICMP. It attaches to the
  VM once tailnet SSH works on NixOS, then SSH leaves the list.
- **On the host:** the NixOS firewall, in its own table `inet nixos-fw`. It allows Tailscale's UDP
  port in public and trusts `tailscale0` and the k3s interfaces. `networking.nftables.flushRuleset`
  stays off, because the NixOS default flushes every table on reload. imp owns `inet imp_host` and
  `inet imp_egress`, and k3s and Docker own their own chains. The host `FORWARD` chain is shared by
  Docker and k3s; imp checks it on the first NixOS boot.

### Infrastructure as code: Pulumi in TypeScript, on Bun

One Pulumi program owns every cloud resource:

| Provider             | Manages                                                                               |
| -------------------- | ------------------------------------------------------------------------------------- |
| Onidel (ours, Go)    | the VM, its SSH key, the cloud firewall and rules, rDNS                               |
| `@pulumi/cloudflare` | the tunnel and its config, DNS for `geoff.cloud`, the health-check Worker, R2 buckets |
| `@pulumi/tailscale`  | the policy file, tags, auth keys (`TailnetKey`), DNS settings                         |
| `@pulumi/kubernetes` | the k3s workloads                                                                     |

- **Onidel provider:** no Terraform or Pulumi provider exists. We write a partial one in Go with
  `pulumi-go-provider`'s `infer` package. It has only the resources we use, and Pulumi generates its
  TypeScript SDK. It lives in this repo; it can become its own public repo later.
- **Block volumes:** Onidel's API has no volume calls. The volume is a documented manual step.
- **Host config:** the NixOS flake, not Pulumi. Pulumi triggers `nixos-anywhere` once and
  `nixos-rebuild switch --target-host` on change, through the `command` provider, so that one
  `pulumi up` converges the whole system.
- **State:** Pulumi's S3 backend on Cloudflare R2 (`geoff-cloud-state`), with a passphrase secrets
  provider.

### Secrets: 1Password `cloud` vault

| Item                    | Used by                                      |
| ----------------------- | -------------------------------------------- |
| `onidel-api`            | the Onidel provider                          |
| `cloudflare-api`        | the Cloudflare provider                      |
| `r2-pulumi-state`       | the Pulumi backend                           |
| `tailscale-oauth`       | the Tailscale provider                       |
| `pulumi-passphrase`     | the Pulumi secrets provider                  |
| `imp-tailscale-authkey` | imp, until Pulumi mints it as a `TailnetKey` |

The committed `.env` holds only `op://` references, resolved with `op run`. Nothing secret is
committed: the repo is public, and gitleaks runs in lefthook and in CI.

### Observability

- **Self-hosted** in k3s: Prometheus, Loki, Grafana and Alloy. Budget about 1 GiB RAM and under 30
  GB of disk, with 30 days of retention.
- **Grafana** is a NodePort (30300) bound to the tailnet range only, at `http://geoffcloud:30300`.
  NixOS also filters forwarded traffic, so no NodePort is public.
- **External check:** monitoring on the same host cannot report that the host is down. The Worker
  `geoff-cloud-health-check` (`workers/health-check/`) runs every 5 minutes from Cloudflare's edge
  and probes `mcp.geoff.cloud`. A 530 means the tunnel or the host is down, a 502 or 504 means the
  PC or atc is down. It keeps the last state per target in an R2 bucket, and on a change it logs and
  posts to `ALERT_WEBHOOK_URL` when that is set. It has no public URL.

### Backups

- imp backs up its own imps (restic) to an R2 bucket.
- k3s state is small and rebuilt from code; its datastore snapshot goes to R2 too.
- Onidel snapshots of the VM before risky host changes, through the API.

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

## Repo layout

```text
provider/      Go: the partial Onidel Pulumi provider
sdk/onidel/    generated TypeScript SDK for it (workspace package)
infra/         Pulumi program (TypeScript, Bun)
nixos/         flake: hosts/geoffcloud, disko, modules
docs/          this page and the runbooks
```

## Roadmap

1. **Now:** repo scaffold, the Onidel provider, Pulumi with the Onidel VM imported, Tailscale policy
   imported, Cloudflare zone and R2.
2. **Host:** NixOS reinstall with k3s, the imp module, firewalls, tailnet SSH.
3. **Ingress:** cloudflared to Geoff's PC, `mcp.geoff.cloud` live for atc.
4. **Ops:** observability, the external check, backups, drift detection in CI.
5. **Later:** more workloads. The atc daemon moves to `geoffcloud`, with agents in imp, so that the
   system works with Geoff's PC off. Bare metal, and more k3s nodes, when nested virtualization
   costs too much.

## Risks and open questions

- **Secure Boot.** The VM boots UEFI with Secure Boot on. Kernel lockdown blocks the unsigned kexec
  that `nixos-anywhere` uses, and the NixOS ISO is unsigned. Secure Boot goes off in the Onidel
  panel for the install. `lanzaboote` can turn it back on later with our own keys.
- **The ZFS kernel pin** can hold the kernel back behind the NixOS default.
- **The shared `FORWARD` chain** between Docker and k3s may need an explicit rule.
- **The ingress hop to the PC** needs the PC online and `tailscale serve` running. That is accepted
  until the daemon moves to the cloud.
- **Pulumi `Acl` takeover**: see the caution under Tailnet.
