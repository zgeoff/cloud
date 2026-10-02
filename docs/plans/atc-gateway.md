# Plan: atc-gateway on geoffcloud

Status: **validated package, not deployed.** The gateway binary does not exist yet (atc builds it as
layer 7 of its integration stack). The package below is validated locally and in CI, with atc
2.10.0's `atc mcp --http` standing in for the gateway. Every step that adds a listener, a
credential, a tailnet grant, a DNS record or an OAuth change waits for Geoff's approval:
[the operator checklist](../runbooks/atc-gateway-operator-checklist.md) orders them.

Sources: atc's provisional interface facts and imp's answers from imp main 43f22974 (2026-10-03),
and the live cluster as checked on 2026-10-03. Facts marked _draft_ come from designs that are not
merged.

## The package

| Part                                                  | File                                                                                                                                    | Validated by                                       |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| Pins (atc release, checksum, base and restic digests) | `deploy/atc-gateway/versions.env`                                                                                                       | the fixture test                                   |
| Gateway image                                         | `deploy/atc-gateway/Dockerfile`, `scripts/fetch-atc-release.sh`                                                                         | the fixture test                                   |
| Backup image and script                               | `deploy/atc-gateway/backup/`                                                                                                            | the fixture test (backup, wipe, restore)           |
| k3s workload, off by default                          | `infra/atc-gateway.ts`, `infra/build-atc-gateway-spec.ts`, `infra/create-atc-gateway-backup-job.ts`, `infra/load-atc-gateway-inputs.ts` | `bun run preview`, off and on                      |
| Restore Job                                           | `deploy/atc-gateway/restore-job.yaml`                                                                                                   | client dry run                                     |
| Cloud daemon, off and not imported                    | `nixos/modules/atc-daemon.nix`                                                                                                          | `nix build ./nixos#checks.x86_64-linux.atc-daemon` |
| Image CI, publish on demand                           | `.github/workflows/atc-gateway-images.yml`                                                                                              | its own run                                        |
| Readiness checks                                      | `scripts/check-atc-gateway-readiness.sh`                                                                                                | run against the live cluster                       |
| Backup and restore                                    | `docs/runbooks/atc-gateway-backup-restore.md`                                                                                           | the fixture test                                   |
| Operator checklist                                    | `docs/runbooks/atc-gateway-operator-checklist.md`                                                                                       | —                                                  |

### Contract facts found in atc's code (2.10.0)

- The server answers only requests whose Host is its public host, `127.0.0.1:<port>`,
  `localhost:<port>` or an allowed host; any other Host gets 403. So the probes send the public
  Host, and cloudflared keeps sending it (`httpHostHeader`).
- A non-loopback bind needs an https public URL behind a TLS-terminating proxy or tunnel.
- State lives in `$HOME/.local/state/atc` (`mcp-auth.db`, `atc.db`); config in `$HOME/.config/atc`,
  which atc writes at start; sockets in `$XDG_RUNTIME_DIR`. With a read-only root, each needs its
  own writable volume.
- A compiled Bun binary extracts native code to `/tmp` and maps it, so `/tmp` must allow exec. A
  Docker tmpfs does not by default; a k8s emptyDir does.

## Shape

```
client (Claude, ChatGPT)
  │ https://atc.geoff.cloud            (Cloudflare edge, always HTTPS)
  ▼
cloudflared (k3s, ingress ns)          tunnel geoff-cloud
  │ http://atc-gateway.atc.svc:8414
  ▼
atc-gateway (k3s, atc ns, 1 replica)   OAuth (better-auth) + named daemon registry
  │ tailnet, tcp 8415, bearer token per daemon
  ├──► cloud daemon (geoffcloud)       ──► impd (tag:imp:7070) ──► one imp per harness
  └──► PC daemon (home-wsl)            later
```

- The gateway owns the public MCP origin and the OAuth issuer. It dials daemons; daemons never dial
  out (v1). Daemons run the harnesses; the gateway never talks to impd.
- One replica: the state is SQLite, which takes one writer.

## Components

### 1. Image

atc ships `atc-gateway` as a Bun-compiled linux-x64 binary next to `atc`. No image exists, so cloud
owns a thin one:

- Base: `gcr.io/distroless/cc-debian12` (the binary needs glibc only), non-root user, read-only
  root.
- Build: a CI job in this repo downloads the release binary for a pinned version, checks its
  checksum, and pushes `ghcr.io/zgeoff/atc-gateway:<atc-version>`. GHCR is free for a public image.
- Template: [Image build](#template-image-build).

### 2. Workload (k3s)

New namespace `atc`. Deployment `atc-gateway`, 1 replica, `strategy: Recreate` (no two writers),
Service `ClusterIP` on 8414. Liveness `GET /healthz`, readiness `GET /readyz` (_draft_: atc adds
both in the gateway PR). Requests 50m CPU / 128 Mi; limit 256 Mi. The node has about 22 GiB free.

The gateway binds the pod interface with plain HTTP. The public URL is https behind the tunnel,
which atc's non-loopback rule allows (_draft_, to be checked against the gateway PR).

### 3. State

Two SQLite files, each under 100 MB, both secret-bearing:

| File          | Holds                                               |
| ------------- | --------------------------------------------------- |
| `mcp-auth.db` | OAuth clients, consents, grants, token records      |
| `gateway.db`  | daemon registry, event cursors, daemon token hashes |

- Volume: a 1 Gi PVC. **Caution:** the default class `local-path` puts it on the root disk with
  reclaim `Delete`. Use a dedicated StorageClass with `reclaimPolicy: Retain`, so a deleted claim
  never deletes OAuth state.
- The root disk is in the Onidel snapshots, so these files will sit in every later snapshot, in
  plain form, behind the Onidel account. The same holds today for the k3s datastore (tunnel token,
  Grafana password).
- Backup: restic to R2, encrypted on the host before upload, under a new prefix
  `atc-gateway/geoffcloud` in `geoff-cloud-backups`, with its own restic password. A CronJob takes a
  consistent copy (`sqlite3 .backup`) first. This needs a new credential: see the approval list.
- Restore: stop the gateway, restore both files from restic, start it. A runbook comes with the
  first deploy; a restore is tested once before the gateway carries real clients.

### 4. Config and secrets

| Setting                            | Secret | Source                                        |
| ---------------------------------- | ------ | --------------------------------------------- |
| `--public-url`                     | no     | `https://atc.geoff.cloud`                     |
| `--host`, `--port`                 | no     | pod IP (`0.0.0.0`), 8414                      |
| state dir                          | no     | `/home/nonroot/.local/state/atc` (the claim)  |
| daemon registry (name → host:port) | no     | ConfigMap from Pulumi                         |
| default daemon                     | no     | ConfigMap                                     |
| bearer token per daemon            | yes    | 1Password `cloud` vault → k8s Secret (Pulumi) |
| better-auth secret, if any         | yes    | 1Password → k8s Secret                        |

Env var names arrive with atc's gateway PR. Secrets follow the existing pattern: 1Password item →
`op run` → Pulumi secret → k8s Secret. Never in the repo, never logged.

### 5. Tailnet

The gateway pod's tailnet traffic leaves through the host's node, as `tag:cloud`.

- **Cloud daemon** (on geoffcloud): reached locally, with no grant (section 7).
- **PC daemon** (later): a grant `tag:cloud → tag:atc-daemon:8415`, and a new tag `tag:atc-daemon`
  (owned by `autogroup:admin` and itself). home-wsl is a member device today, so the PC daemon needs
  a tagged node of its own, or a host-alias grant like the existing `home-pc` one.
- **Narrower option:** a Tailscale sidecar gives the gateway pod its own `tag:atc-gateway`, so only
  that pod (not every pod on the host) reaches daemons. It costs one more auth key. Worth it once a
  second daemon exists.

### 6. Public route

- DNS: proxied CNAME `atc.geoff.cloud` → the existing tunnel. The tunnel ingress gains
  `atc.geoff.cloud → http://atc-gateway.atc.svc.cluster.local:8414` (the whole host; atc routes `/`,
  `/mcp`, `/.well-known/*` and `/api/auth/*` itself).
- `mcp.geoff.cloud` stays on the PC origin until the cutover, then becomes a redirect or is removed,
  as atc decides.
- Always-HTTPS already covers the zone.
- Health check: add `https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp` as a target.

### 7. Cloud daemon

atc has not named the cloud daemon host. On geoffcloud it runs as a NixOS service next to imp-host,
not in k3s, with its listener on the host's tailnet address, tcp 8415.

- **Identity.** On the host it shares the host's tailnet node, so its traffic leaves as `tag:cloud`.
  The gateway pod reaches it on the same host without crossing the tailnet, so that hop needs no
  grant; the per-daemon bearer token still gates it. Only a daemon on another machine (the PC later)
  needs `tag:atc-daemon` and a grant from the gateway.
- **impd access.** impd's oRPC API is at `/rpc` on tag:imp tcp 7070 (wake proxy 7080), with the
  `@zgeoff/imp-client` SDK. Requests need a Host header naming impd. The daemon needs a grant
  `tag:cloud → tag:imp:7070`, and one of:
  - **a named impd token** (recommended):
    `imp token new atc-cloud --scope manage --imps 'harness-*'`. `manage` is the least scope that
    can create and destroy; the pattern confines it to harness imps. A pattern token must name each
    imp it creates, and cannot pass `--net`. Stored in 1Password, injected through a root-only file.
  - **tailnet identity** (no token): `IMP_TAILNET_IDENTITIES` matching `tag:cloud`. Simpler, but
    every pod and service on geoffcloud then gets that scope over impd. Not recommended.
- **Leases.** imp adds generic `leases.acquire/renew/release/list` (owner = the caller's identity
  plus a label, ttl 10–3600 s, scope `exec`). imp stays generic: no harness-specific API. Until
  leases land, `imps.hold` is one shared value and not a lease.

### 8. Harness imps

One imp per harness, from a reusable image plus a clean checkout. No dirty-directory transfer, and
no subscription credentials copied from the PC.

- **Image.** A harness image is any Dockerfile; it lives in the atc repo (imp stays harness-unaware)
  and is built on the host with `imp image build <dir> --name <n>`, which runs `docker build`
  through impd. There is no registry import flow. imp's `images/dev` (Node, Bun, Go, Python, a
  harness CLI) is the likely base.
- **Clean checkout**, one of:
  - **self-clone through imp's broker** (recommended): `imp secret add github --kind github` and
    `imp grant <imp> github`. The broker injects auth for git over HTTPS to github.com; the guest
    sees only a placeholder. HTTPS only, no deploy keys. Needs a GitHub token: whose, and which
    scope, is Geoff's call. A fine-grained token, read-only on the named repos, is the least.
  - **host push**: `imp cp ./dir imp:/path` (needs `manage`). Only from a clean checkout the daemon
    makes itself, never from the PC's working tree.
  - **template**: set up one imp, remove its secrets, `imp template create`, then
    `imp new --image <template>` (a ZFS clone; machine-id and SSH host keys reset on first boot).
    Fast start, but the checkout ages; pair it with a `git fetch` on start.
- **Bounds.** Per imp: `--cpus 2 --memory 2048 --disk 32` (the defaults) to start. The host's RAM
  budget is 20 GiB (`IMP_RAM_BUDGET_MIB=20480`), so about 9 awake harnesses at 2 GiB with headroom;
  idle imps sleep to disk and cost no RAM. A boot that does not fit fails with
  `RAM_BUDGET_EXCEEDED`.
- **Egress.** `--policy box --allow` the git host, the package registries and the model endpoints.
  Broker-granted hosts stay reachable under every policy.
- **Harness login.** imp's `anthropic` broker kind is an API key, not a subscription login. How a
  harness signs in is open and researched separately in the integration review.

## Order of work and approvals

[The operator checklist](../runbooks/atc-gateway-operator-checklist.md) holds the ordered steps,
what each waits on, the approval each needs and its effect. It is the single list; this plan does
not repeat it.

## Readiness checks

`scripts/check-atc-gateway-readiness.sh` runs read-only checks and prints one line per check: what
exists, what is missing, nothing secret. It changes nothing.

## Templates

The sketches that stood here are replaced by the validated files in [the package](#the-package).
