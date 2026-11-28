# Public ingress

The estate has one way in from the internet: Cloudflare tunnels, four of them, which a cloudflared
connector holds open from inside the estate. The host opens no inbound port for them. Each route is
a rule in a tunnel's configuration plus a proxied DNS record that points at that tunnel, and Pulumi
declares both. Each workload behind a route brings its own authentication.

The impd tunnel serves `impz.geoff.cloud`, imp's own MCP and OAuth route, which a hosted assistant
signs in to and calls at `https://impz.geoff.cloud/mcp`. The atc tunnel serves `atc.geoff.cloud`,
the atc gateway, which runs its own OAuth server. The boxxy tunnel serves `boxxy.geoff.cloud`, the
boxxy server's public door, which runs its own OAuth server too. The shared tunnel serves two
hostnames, a third while pepys runs, and a fourth while pepys's API is public.
`preview-webhook.geoff.cloud` reaches the preview service's webhook listener, which checks the
signature of every GitHub delivery. `files.geoff.cloud` reaches the files service, which serves each
file to anyone who holds its link and checks a role token on every write.
`pepys-webhook.geoff.cloud` reaches pepys ingest, which checks the signature of every GitHub
delivery. `pepys.geoff.cloud` reaches pepys's API, whose own OAuth server checks every MCP call.
Cloudflare Access adds an owner-only login in front of the sign-in pages of the gateway, the door
and pepys's API, and nowhere else. [The atc gateway](../workloads/atc-gateway.md),
[the boxxy server](../workloads/boxxy.md), [the preview service](../workloads/preview.md),
[the files service](../workloads/files.md) and [pepys](../workloads/pepys.md) cover what answers
behind each route.

## The tunnels

Every tunnel takes its routes from Cloudflare rather than from a file in the estate, so a route
change is a Pulumi change to a tunnel's configuration, and cloudflared picks it up with no redeploy.
A tunnel's configuration is an ordered list, and cloudflared takes the first rule that matches. Each
list ends with a catch-all that answers 404, so a hostname with no rule of its own, or any other
name that reaches the tunnel, gets a 404 and never a workload. Each rule's pattern matches whole
paths only, so any other path, including a variant of a listed one such as `/login/` or `/LOGIN`,
falls to the catch-all. Each hostname is a proxied CNAME to its tunnel, so it resolves to
Cloudflare's edge and never to the host.

### The impd tunnel

`impz.geoff.cloud` must resolve to addresses other than the host's own, because nixie refuses an MCP
server whose name resolves to the host's addresses. It has a proxied CNAME, which resolves to
Cloudflare's addresses, as pepys's and boxxy's names do. Its connector is the `cloudflared-impz`
service on the host, which `nixos/hosts/geoffcloud/configuration.nix` defines and which reaches
impd's public listener on the host's loopback address. imp-host publishes that listener on the
loopback address alone, and impd serves no route there but its own MCP, OAuth and discovery paths
([imp's guide to the public route](https://github.com/zgeoff/impz/blob/main/docs/guides/mcp.md#public-route)).

The tunnel's list holds one rule for the hostname, an exact match of those paths, then the
catch-all. A path outside the list gets the tunnel's 404 and never reaches impd. That includes a
case change, a trailing slash and a dot segment that would resolve to a listed path. No Access login
fronts impd's sign-in pages: impd checks the owner's passkey itself, and the pages were open to the
internet before the tunnel. cloudflared passes the request's `Host` and `Authorization` through, so
impd still names `https://impz.geoff.cloud` as its OAuth issuer and resource.

The connector reads the tunnel's token from `impd-mcp-tunnel-token` in the host's secrets directory,
which the `impdMCPTunnelToken` stack output holds. The unit is skipped while that file is missing,
so a host switch never fails on it. Until the connector runs, the hostname answers with Cloudflare's
error page. The host keeps no port 443 open, no TLS front and no certificate for the name.

Cloudflare's proxy ends a response that stays silent past its read timeout, and an MCP event stream
can sit quiet that long. impd's MCP transport writes a keepalive comment to every stream every 5
seconds, which keeps an MCP event stream under that timeout. The per-address rate limit that the
host's front applied does not apply now: impd counts its limits per client and grant, never per
address, and every request now reaches it from the connector.

### The shared tunnel

The shared tunnel's cloudflared runs in k3s, in its own namespace, as two replicas that each hold
connections to Cloudflare's edge with the tunnel's token. The tunnel serves while either replica is
connected, so one replica's restart drops no traffic. Its list holds the preview webhook's rule,
which matches the path `/webhook` alone and routes it to the listener on the host's tailnet address,
which the host admits only from pod addresses. It then holds the files service's rule, which has no
path pattern, so every path of `files.geoff.cloud` reaches the service's cluster address and the
service answers 404 for any path it does not serve. While pepys runs, pepys's rule follows. Its path
pattern lists exactly the ingest routes that pepys marks public, so every other path of
`pepys-webhook.geoff.cloud` gets the tunnel's 404. While pepys's API is public, two rules for
`pepys.geoff.cloud` come last: the browser paths of
[the API's route boundary](#the-pepys-apis-route-boundary), which cloudflared admits only with an
Access token, then its machine paths. Both reach the API's Service, and the API answers only a
request whose `Host` names its public host, which cloudflared passes through.

### The atc tunnel

The atc tunnel serves the gateway's hostname alone, so that the gateway can tell a request that came
through Cloudflare from one that did not. Its connector is a cloudflared sidecar in the gateway's
pod, which reaches the gateway on the pod's loopback address instead of through the Service. Only a
process inside the pod, or a port-forward to it, connects from loopback, so the gateway trusts the
forwarded client address on a request from there and on no other
([the gateway's security events](../workloads/observability.md#sign-in-alerts)). The sidecar reads
its token from a file that only it mounts.

The atc tunnel's list holds two rules for the gateway's hostname, then the catch-all. The first rule
matches the browser paths of the [route boundary](#the-gateways-route-boundary), and the second
matches its machine paths. The sidecar restarts with the gateway, so the hostname is down while the
pod restarts. It keeps its metrics on loopback, where kubelet cannot probe them, so the external
health check on the hostname is the atc tunnel's one monitor.

cloudflared passes the request's own host header through to the gateway. The gateway answers only
requests addressed to its public host or to loopback, so a request that reached its Service by any
other name gets a 403.

### The boxxy tunnel

The boxxy tunnel serves the boxxy server's public door, the owner's MCP tools behind OAuth, the same
way the atc tunnel serves the gateway: its connector is a cloudflared sidecar in the server's pod,
and the door listens on the pod's loopback address alone. No Service, no container port and no other
pod reach the door, so the server's ingress NetworkPolicy still admits nothing, and the door trusts
the forwarded client address only from loopback. The sidecar reads its token from a file that only
it mounts.

The boxxy tunnel's list holds two rules for the door's hostname, then the catch-all, as
[the door's route boundary](#the-boxxy-doors-route-boundary) sets out. The owner listener's `/rpc`
and `/healthz` are in neither rule, so the tunnel answers them with its 404 and never reaches the
server. The sidecar restarts with the server, so the hostname is down while the pod restarts. It
keeps its metrics on loopback, and no external health check watches the hostname.

## HTTPS and the edge

The zone redirects plain HTTP to HTTPS on every proxied hostname, so a client that names an
`http://` URL is sent to the encrypted one. The redirect cannot protect a bearer token or an
authorization code in that first plain request, because the request already holds it by the time the
edge answers. A client must therefore use `https://` URLs from the start; the redirect is for a
client that gets it wrong once.

## Authentication belongs to the workload

The gateway is an OAuth 2.1 issuer and authenticates every MCP call itself, so the tunnel carries
traffic and decides nothing about who may make an MCP call. Its discovery, token and revocation
endpoints and the MCP endpoint must answer a client that has no browser and no Cloudflare login,
which an Access login in front of them would break. Cloudflare Access therefore never fronts the
whole hostname. It fronts only the pages that the owner's browser loads to sign in and approve a
client, which no MCP client calls. pepys's API follows the same split, with a passkey behind Access
for the owner's sign-in.

The files service has no Access login either, because GitHub's image proxy fetches each file in a
pull request without one. A read needs only the link, whose random ID nobody can guess, and every
upload, listing, expiry change or removal needs one of the service's two role tokens.

Each public route's registry entry names its auth layer, and the Pulumi program fails on a public
entry without one ([the exposure registry](./firewalls.md#the-exposure-registry)), so a new route
states who authenticates its calls before it can go public.

### The gateway's route boundary

The atc gateway's routes split by caller. The split follows the route table of atc's MCP HTTP
server, and the tunnel and the Access application both read it from one list in the Pulumi program.
A route atc adds later reaches nothing until it joins that list. The typed fleet API at `/rpc`,
which nixie calls with its service token, takes a pattern beside the list: `/rpc` and then one or
more segments of letters, digits, `_` and `-`, such as `/rpc/session/list`.

| Path                                        | Methods atc serves | Caller            | At the edge  |
| ------------------------------------------- | ------------------ | ----------------- | ------------ |
| `/oauth2/authorize`                         | GET                | the owner browser | Access login |
| `/login`                                    | GET, POST          | the owner browser | Access login |
| `/enroll`                                   | GET, POST          | the owner browser | Access login |
| `/consent`                                  | GET, POST          | the owner browser | Access login |
| `/error`                                    | GET                | the owner browser | Access login |
| `/mcp` and its alias `/`                    | POST               | an MCP client     | straight in  |
| `/oauth2/token`                             | POST               | an MCP client     | straight in  |
| `/oauth2/revoke`                            | POST               | an MCP client     | straight in  |
| `/.well-known/oauth-authorization-server`   | GET                | an MCP client     | straight in  |
| `/.well-known/oauth-protected-resource`     | GET                | an MCP client     | straight in  |
| `/.well-known/oauth-protected-resource/mcp` | GET                | an MCP client     | straight in  |
| `/rpc/<procedure path>`                     | POST               | a program         | straight in  |
| any other path                              | none               | none              | tunnel 404   |

The gateway's liveness and readiness probes are in no row, because the kubelet calls them inside the
cluster. The external health check reads the MCP resource's metadata instead.

### The boxxy door's route boundary

The door's routes follow the route table of the door in `@boxxy/auth-oauth`, and the tunnel and its
Access application both read them from one list in the Pulumi program. The split is the gateway's,
except that the door serves no alias of `/mcp` at `/`. A route the door adds later reaches nothing
until it joins that list.

| Path                                                           | Caller            | At the edge  |
| -------------------------------------------------------------- | ----------------- | ------------ |
| `/oauth2/authorize`, `/login`, `/enroll`, `/consent`, `/error` | the owner browser | Access login |
| `/mcp`                                                         | an MCP client     | straight in  |
| `/oauth2/token`, `/oauth2/revoke`                              | an MCP client     | straight in  |
| `/.well-known/oauth-authorization-server`                      | an MCP client     | straight in  |
| `/.well-known/oauth-protected-resource` and its `/mcp` form    | an MCP client     | straight in  |
| any other path, `/`, `/rpc` and `/healthz` among them          | none              | tunnel 404   |

### The pepys API's route boundary

pepys's API serves the same OAuth and MCP paths as the gateway, from the route table of its own
OAuth server, which [`pepys-api-paths.ts`](../../../infra/ingress/pepys-api-paths.ts) copies. The
tunnel and the Access application both read that list. The server takes no dynamic client
registration, so it serves no register path.

| Path                                                           | Caller            | At the edge  |
| -------------------------------------------------------------- | ----------------- | ------------ |
| `/oauth2/authorize`, `/login`, `/enroll`, `/consent`, `/error` | the owner browser | Access login |
| `/mcp` and its alias `/`                                       | an MCP client     | straight in  |
| `/oauth2/token`, `/oauth2/revoke`                              | an MCP client     | straight in  |
| `/.well-known/oauth-authorization-server`                      | an MCP client     | straight in  |
| `/.well-known/oauth-protected-resource` and its `/mcp` form    | an MCP client     | straight in  |
| `/rpc` and every path under it, and any other path             | none              | tunnel 404   |

`/rpc` checks no credential, so it must never join the list. A test of the route builder fails when
an `/rpc` path matches a rule, or when a browser path reaches the API without Access.

### The owner-only Access applications

Three self-hosted Access applications cover the browser paths: one on `atc.geoff.cloud`, one on
`boxxy.geoff.cloud` and one on `pepys.geoff.cloud`. Access covers each path and every path under it.
Each application's one policy allows the owner's address, which the stack config holds as a secret
in `atcGatewayOwnerEmail`, signed in with Access's one-time PIN, and the application offers no other
login. The applications share the account's one one-time PIN login. Access denies every identity
that no allow policy matches, so any other address gets no PIN-backed session. The machine paths lie
outside the application, so they get no login redirect, no challenge and no Access cookie
requirement.

cloudflared checks the Access token on the browser rule itself. A request on a browser path reaches
the gateway only with a token that Access signed for this application, so a request that skipped
Access at the edge still never reaches a sign-in page. The Pulumi program reads the team name that
cloudflared needs from the account's Zero Trust organization.

Passing Access grants nothing inside atc or boxxy. The gateway still signs the owner in, binds each
request, asks for explicit consent, and checks PKCE, the redirect, the Host and Origin headers, the
scope and the resource before it issues a token, and the boxxy door makes the same checks
([the public door](../workloads/boxxy.md#the-public-door)). Each keeps its grants and tokens in its
own database, so a change to an Access application or its policy leaves every grant and token valid.
A rollback of this edge control reverts the Access resources and the tunnel's two rules together,
and leaves the workload's own authentication as it is.

### Other ways to the gateway

The gateway's Service is a cluster address only, so the tunnel is its one public way in, and the
host opens no public port to the cluster. Only the owner's tailnet reaches it otherwise: an admin
with the k3s API over the tailnet can port-forward to the Service, and a process on the host can
reach the Service's cluster address. That administrative path is trusted separately, through the
tailnet policy, and the gateway still answers it only for its public host name.

A port-forward reaches the gateway from the pod's loopback, the address the gateway trusts to set
the forwarded client address, so whoever can open one can forge that address. The Pulumi program
fails its preview on any Role, ClusterRole or binding that grants a port-forward, the Helm charts'
rendered objects included. That leaves the k3s admin kubeconfig as the one holder, and it already
controls the gateway's pod, Secrets and logs.

## Adding a route

Each public service gets one host of its own, `<service>.geoff.cloud`, and a service that speaks MCP
serves it at `/mcp` on that host, as `atc.geoff.cloud/mcp` and `impz.geoff.cloud/mcp` do. A
service's OAuth issuer and its discovery metadata name the same host.

A new public route is the exception in this estate. A service stays on the host or the tailnet
unless its PR states why it must be public, and the route is then a tunnel rule ahead of the
catch-all and a proxied record for its hostname, reviewed in the same preview. The hostname needs a
public entry in the [exposure registry](./firewalls.md#the-exposure-registry) that names its auth
layer, and the Pulumi program refuses a route to any other hostname. impd's tailnet names under
`imps.geoff.cloud` never pass through a tunnel
([imp on the host](../host/imp.md#dns-and-certificates)).

The host's TLS front, Caddy with one `front-route` entry per hostname, is a module that no host
enables now. `impz.geoff.cloud` was its one route, and it moved to the impd tunnel above. Use it
again for a route that cannot take a proxy's limits. Add a front-route entry to the registry with
the hostname, upstream and paths for the front. Pulumi reads the same entry to create the DNS-only
records.
