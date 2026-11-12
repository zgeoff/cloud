# The boxxy server

The boxxy server decides which task the fleet of coding agents works on next, and measures what each
task costs. It runs in k3s as one pod in the `boxxy` namespace, with its SQLite store on its own
volume, and a nightly job backs that store up to R2 once the backup is configured. The server
belongs to [zgeoff/boxxy](https://github.com/zgeoff/boxxy), which publishes it to npm as
`@boxxy/server`; this repo builds the image and runs it.

## The two listeners

The server opens two listeners, and each has its own Service:

| Listener | Port | Service                               | Serves                     | Token                             |
| -------- | ---- | ------------------------------------- | -------------------------- | --------------------------------- |
| owner    | 8090 | `boxxy`, no fixed address             | `/healthz`, `/rpc`, `/mcp` | none                              |
| worker   | 8091 | `boxxy-worker`, on a pinned ClusterIP | `/rpc`, `/mcp/session`     | the worker token on every request |

The owner listener takes no token, so it gets no route: no Ingress, tunnel or tailnet name points at
it, and the owner reaches it with a port-forward over SSH
([the runbook](../../runbooks/boxxy.md#reach-the-owner-listener)). Its ingress NetworkPolicy admits
no pod to either port. A port-forward still reaches the owner port, since it connects on the pod's
own loopback, which no NetworkPolicy filters.

A worker session runs in an imp, which reaches neither the tailnet nor the cluster. It calls a
made-up host, the broker host in the shared constants, and impd's credential broker sends the
request to a relay on the host, which dials the `boxxy-worker` Service at its pinned ClusterIP. The
broker adds the worker token and the session's imp identity token, so the session holds neither. The
atc daemon's `boxxy` auth profile gives a boxxy session `BOXXY_URL=https://boxxy.imp.internal`, and
the daemon's `boxxy` agent loads the boxxy hook plug-in. No pod reaches port 8091: kube-router
admits the node's own addresses before any policy, so the relay still passes, and the Service's
policy needs no `ipBlock`. The worker Service carries the worker port alone, so the relay's address
never leads to the listener with no token.

Both listeners refuse with 403 a request with an `Origin` header, or a `Sec-Fetch-Site` header other
than `none`, so a proxy in front of either must add neither.

## Configuration and secrets

Pulumi writes the server's configuration file into a ConfigMap, mounted at `/etc/boxxy/config.json`.
The cluster sets the listeners, the store at `/data/boxxy.db`, the rules folder at `/rules`, and the
atc address: the `/mcp` route of the atc gateway's Service, with the gateway's public host, so stack
config `boxxy` needs stack config `atcGateway`. The gateway answers only a request whose `Host` is
its public host, and the Service's DNS name is not that host, so the server sends the public host,
which the cluster takes from stack config `atcGateway.publicURL`. Stack config `boxxy` sets the
rest: the runner ID, the trusted folders of each worker target, and the spawn target. The spawn
target's repos, each a folder or a git source, come from the secret stack config `boxxySpawnRepos`,
because a repo's name can be private and this repo is public. Pulumi then marks the whole file a
secret, so a preview shows no line of it, and an error about the repos names none of them. The file
holds no token: a private repo's git source carries `credentialRef: { name }`, the name of the atc
daemon's environment variable that holds the clone token, which the server passes to atc's spawn.
The namespace's egress deny refuses only the tailnet and Podman's subnet, so the calls to the
gateway's Service, to pepys's Services and to GitHub on 443 need no egress allow. The NixOS check
`network-policy` shows the server's pod reach pepys ingest and the pepys API.

Two sections of stack config `boxxy` are optional. With `pepys: { environment }`, the file gets a
`pepys` section: the boxxy route of pepys ingest and the oRPC route of the pepys API, at their
Services, which needs stack config `pepys`. The server then sends its facts there and reads its two
reports there. pepys ingest and the pepys API must admit the server's pod, which their own policies
decide. With `github: { baseUrl }`, the server links and watches the pull requests of its repos. It
only reads them, and it never merges one. The pod has no broker to add a GitHub credential, so the
token comes from `.env`.

A server before the release that moves its atc calls to MCP calls `/rpc` and sends no `Host`
override, and the gateway refuses both. Run an image built from that release or a later one.

Two tokens reach the pod as variables from a Secret with no fixed name, so a new token rolls the
pod, and two more come from the same Secret when their section is set:

- `BOXXY_WORKER_TOKEN`: the bearer token the broker adds to every worker call. The broker holds the
  second copy.
- `BOXXY_ATC_TOKEN`: the bearer token the server sends to the atc gateway, as an atc service token
  (`atcs_` and 32 or more characters). The gateway reads it from a file that Pulumi builds from the
  same variable ([service tokens](./atc-gateway.md#service-tokens)), and the server is the principal
  `service:boxxy` at the atc daemon.
- `BOXXY_PEPYS_SIGNING_SECRET`, with `pepys`: the key that signs each batch of facts. pepys ingest
  reads the same item.
- `BOXXY_GITHUB_TOKEN`, with `github`: the server's fine-grained token, with `Pull requests: read`
  on the owner's repos, which must cover every repo in `boxxySpawnRepos`.

## The rules

The live rules are in `deploy/boxxy/rules/`, and the image holds them at `/rules`. The folder has no
`.git`, so the server loads it as a plain folder, and a rules change is a new image and a deploy.

## The caller proof

Every session and hook call needs a proven caller: the server checks the imp identity token that the
broker signs, against a trust document for each impd that signs. The trust documents go in
`deploy/boxxy/issuers/`, one `<issuer>.json` per impd, as `impz identity jwks` prints it. Pulumi
mounts them at `/etc/boxxy-issuers` and writes that folder, with the broker host as the audience,
into the configuration file. The folder holds the cloud host's document, `geoffcloud.json`. While
the folder holds no document, the configuration has no `trustedIssuers` section, and the server
refuses every session and hook call.

## Backup and restore

The `boxxy-backup` CronJob exists only when the backup's repository and credentials are configured,
and the server deploys without it otherwise. It runs nightly in the atc gateway's backup image,
whose own entrypoint copies every `*.db` in the volume with SQLite's online backup, checks each
copy's integrity, and takes one restic snapshot into the `boxxy` repository in R2. The snapshots
carry that image's `atc-gateway` tag and host. `deploy/boxxy/restore-job.yaml` restores the store
from a snapshot while the server is stopped. [The runbook](../../runbooks/boxxy.md) covers both.

## Deployment

The `boxxy image` workflow compiles `deploy/boxxy/server.ts` and the `@boxxy/server` version that
`package.json` pins into one binary, adds the rules, and publishes the image from `main` to GHCR as
`ghcr.io/zgeoff/cloud-boxxy:<commit>`. The Pulumi program deploys the server only when stack config
`boxxy` is set, so the deploy needs the owner's change to stack config. The pod runs as a nonroot
user on a read-only root filesystem with every capability dropped. A small memory-backed `/tmp`
takes the temp file SQLite writes for a statement journal; its pages count against the container's
memory limit.
