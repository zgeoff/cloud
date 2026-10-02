# Plan: atc-gateway on geoffcloud

Status: **plan only, provisional.** The gateway does not exist yet (atc builds it as layer 7 of its
integration stack). Nothing here is deployed. Every step that adds a listener, a credential, a
tailnet grant, a DNS record or an OAuth change waits for Geoff's approval of the exact setup; the
[approval list](#approval-list-for-geoff) collects them.

Sources: atc's provisional interface facts and imp's lease contract (2026-10-03), and the live
cluster as checked on 2026-10-03. Facts marked _draft_ come from designs that are not merged.

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
| state dir                          | no     | `/var/lib/atc-gateway` (the PVC)              |
| daemon registry (name → host:port) | no     | ConfigMap from Pulumi                         |
| default daemon                     | no     | ConfigMap                                     |
| bearer token per daemon            | yes    | 1Password `cloud` vault → k8s Secret (Pulumi) |
| better-auth secret, if any         | yes    | 1Password → k8s Secret                        |

Env var names arrive with atc's gateway PR. Secrets follow the existing pattern: 1Password item →
`op run` → Pulumi secret → k8s Secret. Never in the repo, never logged.

### 5. Tailnet

The gateway runs in a pod, so its tailnet traffic leaves through the host's node (`tag:cloud`). Two
ways to give it daemon access:

| Option                                | How                                                                                              | New credential       | Blast radius                                                                                |
| ------------------------------------- | ------------------------------------------------------------------------------------------------ | -------------------- | ------------------------------------------------------------------------------------------- |
| A. Host identity (recommended for v1) | grant `tag:cloud → tag:atc-daemon:8415`                                                          | none                 | any pod on geoffcloud can reach the daemon port; the per-daemon bearer token still gates it |
| B. Own identity                       | Tailscale sidecar in the pod as `tag:atc-gateway`; grant `tag:atc-gateway → tag:atc-daemon:8415` | a Tailscale auth key | the gateway pod only                                                                        |

Either way, daemons get `tag:atc-daemon` (new tag, owned by `autogroup:admin` and itself). The PC
daemon later joins as `tag:atc-daemon` too; today home-wsl is a member device, so that needs either
a tagged second node on the PC or a host alias grant like the existing `home-pc` one.

### 6. Public route

- DNS: proxied CNAME `atc.geoff.cloud` → the existing tunnel. The tunnel ingress gains
  `atc.geoff.cloud → http://atc-gateway.atc.svc.cluster.local:8414` (the whole host; atc routes `/`,
  `/mcp`, `/.well-known/*` and `/api/auth/*` itself).
- `mcp.geoff.cloud` stays on the PC origin until the cutover, then becomes a redirect or is removed,
  as atc decides.
- Always-HTTPS already covers the zone.
- Health check: add `https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp` as a target.

### 7. Cloud daemon

atc has not named the cloud daemon host. On geoffcloud it runs as a NixOS service (not in k3s): it
needs the tailnet listener on 8415 and impd access. It joins as `tag:atc-daemon`, which needs a
grant `tag:atc-daemon → tag:imp:7070` for impd. Details wait for imp's contract below.

### 8. Harness imps

_Pending imp's reply._ One imp per harness, materialized from a reusable image plus a clean repo
checkout. No dirty-directory transfer, and no subscription credentials copied from the PC.

## Order of work

1. **Now (no approval needed):** this plan, the templates below, and the readiness check script.
2. **When atc's gateway PR lands:** fill in env var names and ports; build and push the image (CI in
   this repo). Nothing runs yet.
3. **After Geoff approves the exact setup:** in one Pulumi change, with a preview first: namespace,
   StorageClass, PVC, Secret, ConfigMap, Deployment, Service, the tailnet tag and grants, the tunnel
   ingress, the DNS record, the backup CronJob. Then the restore test.
4. **Cutover (atc and Geoff):** re-add the OAuth clients against the new issuer, move the clients,
   retire the PC origin.

## Approval list for Geoff

Each item is a separate yes or no. None is done.

1. **New hostname** `atc.geoff.cloud` on the existing tunnel (DNS record + tunnel ingress). Free.
2. **OAuth issuer move** to `https://atc.geoff.cloud`: every client re-registers and grants are
   issued again (atc's step, your access change).
3. **New tailnet tag** `tag:atc-daemon`, and grants `tag:cloud → tag:atc-daemon:8415` (option A) or
   a new `tag:atc-gateway` with its own auth key (option B), plus `tag:atc-daemon → tag:imp:7070`.
4. **New credentials** in the `cloud` vault: one bearer token per daemon; a restic password and an
   R2 key scoped to the `atc-gateway/` prefix for the gateway's backups (or reuse the existing
   backups key, which already reaches the bucket: simpler, broader).
5. **New listener** on each daemon host: tailnet tcp 8415.
6. **Snapshots** will contain the gateway's OAuth state once it runs. Accept, as for the k3s
   datastore today, or decide otherwise.

## Readiness checks

`scripts/check-atc-gateway-readiness.sh` runs read-only checks and prints one line per check: what
exists, what is missing, nothing secret. It changes nothing.

## Templates

These are the shapes for step 3. They are not wired into the Pulumi program.

### Template: image build

```dockerfile
# docker/atc-gateway/Dockerfile — built by CI for a pinned atc release
FROM gcr.io/distroless/cc-debian12:nonroot
COPY atc-gateway /usr/local/bin/atc-gateway
USER nonroot
EXPOSE 8414
ENTRYPOINT ["/usr/local/bin/atc-gateway"]
```

### Template: k3s workload (Pulumi, TypeScript)

```ts
// infra/atc-gateway.ts — sketch; flag names and env vars follow atc's gateway PR
const ns = new k8s.core.v1.Namespace('atc', { metadata: { name: 'atc' } }, opts);

const retain = new k8s.storage.v1.StorageClass(
  'local-path-retain',
  {
    metadata: { name: 'local-path-retain' },
    provisioner: 'rancher.io/local-path',
    reclaimPolicy: 'Retain',
    volumeBindingMode: 'WaitForFirstConsumer',
  },
  opts,
);

const state = new k8s.core.v1.PersistentVolumeClaim(
  'atc-gateway-state',
  {
    metadata: { namespace: ns.metadata.name, name: 'atc-gateway-state' },
    spec: {
      storageClassName: retain.metadata.name,
      accessModes: ['ReadWriteOnce'],
      resources: { requests: { storage: '1Gi' } },
    },
  },
  opts,
);

const tokens = new k8s.core.v1.Secret(
  'atc-gateway-daemon-tokens',
  {
    metadata: { namespace: ns.metadata.name, name: 'atc-gateway-daemon-tokens' },
    stringData: {
      /* one entry per daemon, from op:// references */
    },
  },
  opts,
);

new k8s.apps.v1.Deployment(
  'atc-gateway',
  {
    metadata: { namespace: ns.metadata.name, name: 'atc-gateway' },
    spec: {
      replicas: 1,
      strategy: { type: 'Recreate' },
      selector: { matchLabels: { app: 'atc-gateway' } },
      template: {
        metadata: { labels: { app: 'atc-gateway' } },
        spec: {
          securityContext: { runAsNonRoot: true, fsGroup: 65532 },
          containers: [
            {
              name: 'atc-gateway',
              image: `ghcr.io/zgeoff/atc-gateway:${atcVersion}`,
              args: [
                '--host',
                '0.0.0.0',
                '--port',
                '8414',
                '--public-url',
                'https://atc.geoff.cloud',
              ],
              ports: [{ containerPort: 8414 }],
              envFrom: [{ secretRef: { name: tokens.metadata.name } }],
              volumeMounts: [{ name: 'state', mountPath: '/var/lib/atc-gateway' }],
              livenessProbe: { httpGet: { path: '/healthz', port: 8414 } },
              readinessProbe: { httpGet: { path: '/readyz', port: 8414 } },
              resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '256Mi' } },
              securityContext: { readOnlyRootFilesystem: true, allowPrivilegeEscalation: false },
            },
          ],
          volumes: [{ name: 'state', persistentVolumeClaim: { claimName: state.metadata.name } }],
        },
      },
    },
  },
  opts,
);
```

### Template: tunnel ingress and DNS

```ts
// added before the catch-all 404 in infra/index.ts
{ hostname: 'atc.geoff.cloud', service: 'http://atc-gateway.atc.svc.cluster.local:8414' },

new DnsRecord('atc', { zoneId, name: 'atc.geoff.cloud', type: 'CNAME',
  content: tunnel.id.apply((id) => `${id}.cfargotunnel.com`), proxied: true, ttl: 1 });
```

### Template: tailnet policy

```ts
tagOwners: { 'tag:atc-daemon': ['autogroup:admin', 'tag:atc-daemon'] },
grants: [
  // option A: the gateway pod leaves through the host's node
  { src: ['tag:cloud'], dst: ['tag:atc-daemon'], ip: ['tcp:8415'] },
  // the cloud daemon drives impd
  { src: ['tag:atc-daemon'], dst: ['tag:imp'], ip: ['tcp:7070'] },
],
```
