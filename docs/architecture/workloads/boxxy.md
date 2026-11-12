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

The owner listener takes no token, so only the owner's own path may reach it. Its ingress
NetworkPolicy admits the tailnet Traefik's namespace to port 8090 and no other pod.

A worker session runs in an imp, which reaches neither the tailnet nor the cluster. It calls a
made-up host, the broker host in the shared constants, and impd's credential broker sends the
request to a relay on the host, which dials the `boxxy-worker` Service at its pinned ClusterIP. The
broker adds the worker token and the session's imp identity token, so the session holds neither. No
pod reaches port 8091: kube-router admits the node's own addresses before any policy, so the relay
still passes. The worker Service carries the worker port alone, so the relay's address never leads
to the listener with no token.

Both listeners refuse with 403 a request with an `Origin` header, or a `Sec-Fetch-Site` header other
than `none`, so a proxy in front of either must add neither.

## Configuration and secrets

Pulumi writes the server's configuration file into a ConfigMap, mounted at `/etc/boxxy/config.json`.
The cluster sets the listeners, the store at `/data/boxxy.db`, the rules folder at `/rules`, and the
atc address: the `/rpc` route of the atc gateway's Service, so stack config `boxxy` needs stack
config `atcGateway`. Stack config `boxxy` sets the rest: the runner ID, the trusted folders of each
worker target, and the spawn target with its repo paths. The file holds no secret. The namespace's
egress deny refuses only the tailnet and Podman's subnet, so the call to the gateway's Service needs
no egress allow.

The pinned gateway does not answer that address yet, so the server cannot reach atc until a fix
lands. It refuses each request whose `Host` is not its public host with 403, and the Service's DNS
name is not that host. It also serves no `/rpc` route, and answers 404 there even on its public
host. Stack config `boxxy` stays unset until both change.

Two tokens reach the pod as variables from a Secret with no fixed name, so a new token rolls the
pod:

- `BOXXY_WORKER_TOKEN`: the bearer token the broker adds to every worker call. The broker holds the
  second copy.
- `BOXXY_ATC_TOKEN`: the bearer token the server sends to the atc gateway. How the gateway signs the
  server in is not settled.

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
user on a read-only root filesystem with every capability dropped.
