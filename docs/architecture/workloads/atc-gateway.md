# The atc gateway

The atc gateway is atc's public MCP origin. It runs in k3s behind the tunnel, signs clients in as
atc's OAuth issuer, and forwards each call to one of the atc daemons it knows by name. A daemon owns
the sessions and runs them; the gateway never talks to impd and never runs a session itself. The
gateway keeps its clients and its grants in SQLite, so it runs as one replica on a volume that
outlives a deleted claim, and a nightly job backs that volume up.
[Public ingress](../network/public-ingress.md) covers the route in, and
[the agent image](./agent-image.md) covers the image that sessions run on. Each sign-in outcome that
the gateway writes as a security event reaches Discord as an alert, under
[sign-in alerts](./observability.md#sign-in-alerts).

## Daemons and the registry

The gateway reads its daemons from a registry that Pulumi writes from the stack config: each
daemon's name, its tailnet address and port, and the daemon ID it prints on its own host, plus the
default daemon for a call that names none. The gateway checks each daemon's ID when it connects, so
a registry entry that points at the wrong daemon fails instead of reaching it. Each daemon gets its
own bearer token, which the gateway presents and the daemon checks, so a token taken from one
daemon's path opens no other daemon.

The gateway dials; a daemon never dials out. The two daemons sit at different distances:

- **The cloud daemon** runs on the host, so the gateway's traffic reaches the host's own tailnet
  address from the pod network without crossing the tailnet, and needs no tailnet grant. The host's
  narrowing table admits that path to the daemon's port, and the owner's PC beside it
  ([firewalls](../network/firewalls.md#the-narrowing-table)).
- **The PC daemon** runs on the owner's PC and is reached over the tailnet, through the one grant
  `tag:cloud` holds to the PC's daemon port ([the tailnet](../network/tailnet.md)). The PC sleeps,
  so its unreachable alert is a warning, while the cloud daemon's is critical.

A blackbox probe in the cluster opens a TCP connection to each daemon on the gateway's own path to
it, so the alert for a daemon fires when the gateway could not reach it either
([observability](./observability.md)).

An egress NetworkPolicy lets the gateway's pod and the probe's pod reach the two daemons' addresses
on the daemon port, and refuses every other pod in their namespaces, the gateway's backup job among
them ([which pod uses each grant](../network/tailnet.md#which-pod-uses-each-grant)). The policy
takes those addresses from the shared constants, not from the registry, so a daemon added to the
stack config stays unreachable until its address joins the policy.

## The gateway pod

The gateway is atc's released binary in a distroless image that this repo builds. CI builds the
image from the pinned release after checking the release's checksum. Only `main` publishes it: a
push that changes the image pins, or a manual run on `main`, and neither replaces a tag that already
exists. The stack config names each image by digest, so a deploy runs exactly the image that was
checked. After a publish, the workflow opens a pull request that pins the new digests, which merges
and applies as a release bump does ([the release check](../../runbooks/release-check.md)).

The gateway's image and the backup image are private packages on GHCR, so k3s pulls them with a pull
Secret in each namespace that runs one: the gateway's own and nixie's, whose backup runs in the same
backup image. The Secret has a fixed name, because the generated restore Jobs name it. A rotated
token therefore updates the Secret in place, and the kubelet reads it at the next pull without a
rollout ([the GHCR pull token](../../runbooks/ghcr-pull-token.md)).

The pod runs as a non-root user on a read-only root, with writable volumes only where atc writes:
its state, its config, its runtime sockets and its temporary directory. The temporary directory must
allow execution, because a compiled Bun binary unpacks native code there and maps it. The gateway
reads its tokens only at start, so the token Secret has no fixed name: a change to any token
replaces the Secret, and the Deployment rolls onto the new one. The probes send the public host as
their host header, because the gateway refuses any other name.

## State and backup

The gateway's state is two SQLite files: one holds the OAuth clients, consents, grants and token
records, and one holds the routing and outcome of each keyed request the gateway forwards, so a
retried call reaches the daemon that took the first one. The OAuth file holds secrets. SQLite takes
one writer, so the gateway runs as one replica that a rollout stops before it starts the next.

The state sits on a claim of a storage class that keeps its volume when the claim is deleted. k3s's
default local-path class deletes the volume with its claim, and losing the OAuth state would sign
every client out, so the gateway uses a retaining class instead. The volume sits in k3s's data
directory on the encrypted zvol on the second disk, so no Onidel snapshot holds the state
([protection at rest](../secrets.md#protection-at-rest)).

A CronJob backs the state up nightly, and never runs two backups at once. It mounts the gateway's
volume, takes a consistent copy of each database with SQLite's online backup while the gateway keeps
writing, checks each copy's integrity, and uploads the copies to R2 with restic under their own
password. Retention keeps a set of daily and weekly snapshots, and the job filters by its own host
and tag, so it never prunes another tool's snapshots in a shared repository. Every backup reads from
one fixed path, because restic groups snapshots by path and a new path per run would leave every
snapshot in a group of its own, which retention never removes.

A restore runs by hand, as a one-off Job, while the gateway is stopped. It restores a snapshot,
checks each database, and replaces each database file along with its WAL files, so no stale log
replays over the restored state
([the backup and restore runbook](../../runbooks/atc-gateway-backup-restore.md)).

The restore Job's YAML is generated from the same pod builder as the backup CronJob, with explicit
restore overrides, and from the stack config's one pin of the backup image. A CI check fails when
the committed YAML differs from the generated one, so a restore always runs as the backup's user,
with its claim and Secret and in its image.

## Service tokens

A service in the cluster that cannot sign in with a browser calls `/mcp` with a fixed bearer token,
which the gateway reads from a file at start (`--service-token-file`, atc 7.14.0 and later). The
boxxy server is the one such client. Pulumi builds the file from the stack's `BOXXY_ATC_TOKEN` and
the public URL: the resource is the public URL's origin and `/mcp`, and the gateway refuses to start
when the file names another. The client `boxxy` holds the scopes `read`, `spawn`, `message` and
`kill`, and its principal is `service:boxxy`, which the daemon's `principals` lists.

atc refuses a token file that another user owns or that its group or others can open. Kubernetes
makes the files of a Secret volume root's, so no mode on that volume passes for the gateway's user.
An init container in the backup image, running as the gateway's user, copies the file into a memory
volume with mode 0600, and the gateway mounts that volume read-only. The Secret has no fixed name,
so a new token rolls the Deployment.

The input is optional. While `BOXXY_ATC_TOKEN` is unset, the pod has no Secret, no init container,
no mount and no flag. While `images/atc-gateway/versions.env` pins an atc release older than 7.14.0,
or the stack's `atcGateway.image` is older than 7.14.0, the image has no such flag. Pulumi then
leaves them out and prints one warning, so a deploy never starts a gateway that cannot read its
arguments ([the boxxy runbook](../../runbooks/boxxy.md#the-service-token-at-the-atc-gateway)).

## The cloud daemon

The cloud daemon is a NixOS service on the host, running an unpatched atc release that the flake
pins by checksum. It stays byte-identical to the release because an imp target copies the daemon's
own binary into a guest whose image ships another atc release. It listens on the host's tailnet
address, and systemd hands it two tokens as credentials: the bearer the gateway must present, and
the impd token it uses itself. A third credential, the read-only token for cloning private repos,
becomes an environment variable of the daemon's process
([the clone token](../../runbooks/boxxy.md#the-daemons-clone-token)). systemd copies both when the
service starts, and the service then copies the bearer into its runtime directory on tmpfs, owned by
the daemon's user with mode 0600, because atc refuses a token file that another user owns. So a
rotated token reaches the daemon only after a restart; a reload rereads the old copy. The bearer
comes from one 1Password item that both the gateway's Secret and the host's file take, and the
daemon's file holds one token or two, so a rotation needs no outage: add the new token to the host's
file beside the old one and restart the daemon, apply so the gateway rolls onto the new token, then
remove the old one and restart again.

The daemon has one execution target, impd on the host's loopback, and names every imp it creates
with a fixed prefix. Its impd token can create, wake and destroy only imps with that prefix, so a
compromised daemon cannot touch any other imp. The daemon's config lists each gateway client it
serves, with the targets that client may use, and refuses a client it does not list, so it never
falls back to running a session on the host itself.

The target boots each imp from the [agent image](../../runbooks/agent-image.md), and the session
hooks run the image's own atc while it matches the daemon's release, so a spawn uploads no binary.
The daemon offers Claude and Codex. A Claude session signs in through impd's credential broker with
the same profiles as the home-pc daemon's `cloud` target: the Claude subscription, GitHub, Linear's
MCP server and 1Password Connect. The cloud daemon adds the `pepys-telemetry` profile, so every
Claude session sends its OpenTelemetry logs to pepys ingest through the broker
([the telemetry path](./pepys.md#the-telemetry-path-from-a-session)). The profiles name impd's
secrets, never their values, so a renamed or added profile changes the daemons' configs. The
daemon's impd token lists each of those secrets as grantable, so the token, not the config, bounds
what a session can reach. impd ties each entry of that list to the secret it named, so a secret made
again under the same name needs a new grantable list on each daemon's token. A Codex session has no
brokered sign-in.

The daemon also offers the `boxxy` agent for the boxxy server's worker sessions
([boxxy](./boxxy.md)). It is a Claude entry with the same profiles and variables as `claude`, and
the `boxxy` profile beside them, which gives the session `BOXXY_URL` and the broker's token for the
worker listener. Its `args` load the boxxy hook plug-in that the agent image holds. A stock Claude
entry's `auth` takes no `args`, and the plug-in's folder exists only in the guest, so the plug-in
sits in the entry's `args`. atc adds `atc.session.id` to `OTEL_RESOURCE_ATTRIBUTES` in every session
it starts, which joins a session's telemetry to the session.

The `boxxy-review` agent runs the boxxy server's review sessions. It loads the same plug-in, and
selects the `claude`, `pepys-telemetry` and `boxxy` profiles and `github-review`, whose secret
`boxxy-github-token` is the read-only clone token. noslop reads that token as `GH_TOKEN`. No other
agent selects `github-review`, and `boxxy-review` selects no other GitHub profile, so build and
design sessions never get the read-only token, and a review session cannot push.

Two lists name every secret the daemon may grant. The profiles in the host's config name them, and
the grantable list of the daemon's impd token (`scripts/atc-cloud-grantable.ts`) bounds them: `glm`,
`claude-setup-token`, `github-imp-agents`, `linear-imp-agents`, `op-connect`, `pepys-telemetry` and
`boxxy`. A new profile changes both, and the token's list changes by hand
([the boxxy runbook](../../runbooks/boxxy.md#let-sessions-reach-the-server)).

The daemon's `principals` lists the OAuth clients of the gateway and, as `service:boxxy`, the boxxy
server's service token ([service tokens](#service-tokens)). Each is granted the target `geoffcloud`.

A Claude session runs its prompt only in a folder that Claude Code trusts, and the imp's Claude
config trusts only the root of a workspace that the spawn cloned with trust opted in. The daemon
resolves a git workspace's ref with git on the host before the imp clones it. The
[smoke spawn](../../runbooks/atc-gateway-smoke.md) uses those settings.
