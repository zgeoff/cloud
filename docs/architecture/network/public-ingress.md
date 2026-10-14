# Public ingress

The estate has one way in from the internet: a Cloudflare tunnel that cloudflared holds open from
inside the cluster. The host opens no inbound port for it, so a public route exists only as a rule
in the tunnel's configuration and a DNS record that points at the tunnel, and Pulumi declares both.
Each workload behind the tunnel brings its own authentication. The tunnel has two routes:
`atc.geoff.cloud`, the atc gateway, which runs its own OAuth server, and
`preview-webhook.geoff.cloud`, the preview service's webhook listener, which checks the signature of
every GitHub delivery. Cloudflare Access adds an owner-only login in front of the gateway's sign-in
pages, and nowhere else. [The atc gateway](../workloads/atc-gateway.md) and
[the preview service](../workloads/preview.md) cover what answers behind each route.

## The tunnel

cloudflared runs in k3s, in its own namespace, as two replicas that each hold connections to
Cloudflare's edge with the tunnel's token. The tunnel serves while either replica is connected, so
one replica's restart drops no traffic. The tunnel takes its routes from Cloudflare rather than from
a file in the cluster, so a route change is a Pulumi change to the tunnel's configuration, and
cloudflared picks it up with no redeploy.

The tunnel's configuration is an ordered list, and cloudflared takes the first rule that matches.
The list holds two rules for the gateway's hostname, both routed to the gateway's Service in the
cluster, then the preview webhook's hostname, and then a catch-all that answers 404. The first
gateway rule matches the browser paths of the [route boundary](#the-gateways-route-boundary), and
the second matches its machine paths. The webhook's rule matches the path `/webhook` alone and
routes it to the listener on the host's tailnet address, which the host admits only from pod
addresses. Each rule's pattern matches whole paths only, so any other path, including a variant of a
listed one such as `/login/` or `/LOGIN`, falls to the catch-all. The catch-all stays last, so a
hostname with no rule of its own, or any other name that reaches the tunnel, gets a 404 and never a
workload. Each hostname is a proxied CNAME to the tunnel, so it resolves to Cloudflare's edge and
never to the host.

cloudflared passes the request's own host header through to the gateway. The gateway answers only
requests addressed to its public host or to loopback, so a request that reached its Service by any
other name gets a 403.

## HTTPS and the edge

The zone redirects plain HTTP to HTTPS on every hostname, so a client that names an `http://` URL is
sent to the encrypted one. The redirect cannot protect a bearer token or an authorization code in
that first plain request, because the request already holds it by the time the edge answers. A
client must therefore use `https://` URLs from the start; the redirect is for a client that gets it
wrong once.

## Authentication belongs to the workload

The gateway is an OAuth 2.1 issuer and authenticates every MCP call itself, so the tunnel carries
traffic and decides nothing about who may make an MCP call. Its discovery, token and revocation
endpoints and the MCP endpoint must answer a client that has no browser and no Cloudflare login,
which an Access login in front of them would break. Cloudflare Access therefore never fronts the
whole hostname. It fronts only the pages that the owner's browser loads to sign in and approve a
client, which no MCP client calls.

### The gateway's route boundary

The atc gateway's routes split by caller. The split follows the route table of atc's MCP HTTP
server, and the tunnel and the Access application both read it from one list in the Pulumi program.
A route atc adds later reaches nothing until it joins that list.

| Path                                        | Methods atc serves | Caller            | At the edge  |
| ------------------------------------------- | ------------------ | ----------------- | ------------ |
| `/oauth2/authorize`                         | GET                | the owner browser | Access login |
| `/login`                                    | GET, POST          | the owner browser | Access login |
| `/consent`                                  | GET, POST          | the owner browser | Access login |
| `/error`                                    | GET                | the owner browser | Access login |
| `/mcp` and its alias `/`                    | POST               | an MCP client     | straight in  |
| `/oauth2/token`                             | POST               | an MCP client     | straight in  |
| `/oauth2/revoke`                            | POST               | an MCP client     | straight in  |
| `/.well-known/oauth-authorization-server`   | GET                | an MCP client     | straight in  |
| `/.well-known/oauth-protected-resource`     | GET                | an MCP client     | straight in  |
| `/.well-known/oauth-protected-resource/mcp` | GET                | an MCP client     | straight in  |
| any other path                              | none               | none              | tunnel 404   |

The gateway's liveness and readiness probes are in no row, because the kubelet calls them inside the
cluster. The external health check reads the MCP resource's metadata instead.

### The owner-only Access application

One self-hosted Access application covers the browser paths on `atc.geoff.cloud`, and Access covers
each path and every path under it. Its one policy allows the owner's address, which the stack config
holds as a secret, signed in with Access's one-time PIN, and the application offers no other login.
Access denies every identity that no allow policy matches, so any other address gets no PIN-backed
session. The machine paths lie outside the application, so they get no login redirect, no challenge
and no Access cookie requirement.

cloudflared checks the Access token on the browser rule itself. A request on a browser path reaches
the gateway only with a token that Access signed for this application, so a request that skipped
Access at the edge still never reaches a sign-in page. The Pulumi program reads the team name that
cloudflared needs from the account's Zero Trust organization.

Passing Access grants nothing inside atc. The gateway still signs the owner in, binds each request,
asks for explicit consent, and checks PKCE, the redirect, the Host and Origin headers, the scope and
the resource before it issues a token. atc keeps its grants and tokens in its own database, so a
change to the Access application or its policy leaves every grant and token valid. A rollback of
this edge control reverts the Access resources and the tunnel's two gateway rules together, and
leaves atc's own authentication as it is.

### Other ways to the gateway

The gateway's Service is a cluster address only, so the tunnel is its one public way in, and the
host opens no public port to the cluster. Only the owner's tailnet reaches it otherwise: an admin
with the k3s API over the tailnet can port-forward to the Service, and a process on the host can
reach the Service's cluster address. That administrative path is trusted separately, through the
tailnet policy, and the gateway still answers it only for its public host name.

## Adding a route

A new public route is the exception in this estate. A service stays on the host or the tailnet
unless its PR states why it must be public, and the route is then a tunnel rule ahead of the
catch-all and a proxied record for its hostname, reviewed in the same preview. The hostname needs a
public entry in the [exposure registry](./firewalls.md#the-exposure-registry), and the Pulumi
program refuses a route to any other hostname. `imp.geoff.cloud` has a reserved entry, held free for
imp's own public endpoint, and impd's tailnet names under `imps.geoff.cloud` never pass through the
tunnel ([imp on the host](../host/imp.md#dns-and-certificates)).
