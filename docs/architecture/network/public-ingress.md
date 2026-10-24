# Public ingress

The estate has two ways in from the internet: two Cloudflare tunnels that cloudflared holds open
from inside the cluster, and a TLS front on the host's public HTTPS port. The host opens no inbound
port for the tunnels, so a tunnel route exists only as a rule in a tunnel's configuration and a DNS
record that points at that tunnel, and Pulumi declares both. The TLS front serves `mcp.geoff.cloud`,
imp's own MCP and OAuth route, which a hosted assistant signs in to and calls directly. Each
workload behind a route brings its own authentication. The atc tunnel serves `atc.geoff.cloud`, the
atc gateway, which runs its own OAuth server. The shared tunnel serves two hostnames.
`preview-webhook.geoff.cloud` reaches the preview service's webhook listener, which checks the
signature of every GitHub delivery. `files.geoff.cloud` reaches the files service, which serves each
file to anyone who holds its link and checks a role token on every write. Cloudflare Access adds an
owner-only login in front of the gateway's sign-in pages, and nowhere else.
[The atc gateway](../workloads/atc-gateway.md), [the preview service](../workloads/preview.md) and
[the files service](../workloads/files.md) cover what answers behind each route.

## The host's TLS front

Caddy on the host serves each front route of the
[exposure registry](./firewalls.md#the-exposure-registry) on the public addresses' port 443, and
`mcp.geoff.cloud` is its one route. The hostname's A and AAAA records point straight at the host and
are not proxied, for two reasons. Caddy gets the certificate itself, through Let's Encrypt's
TLS-ALPN-01 challenge on port 443, so port 80 stays shut and the host holds no DNS credential for
it. And Cloudflare's proxy would end an MCP event stream that stays quiet past its read timeout.

The front passes only the route's listed paths, which are impd's MCP, OAuth and discovery paths, to
impd's public listener. A path matches only as the request sends it, so a case change, a trailing
slash or a dot segment that would resolve to a listed path gets a 404 from Caddy and never reaches
impd. imp-host publishes the listener on the host's loopback alone, and impd's public listener
answers no other route, the API and the dashboard included
([imp's guide to the public route](https://github.com/zgeoff/impz/blob/main/docs/guides/mcp.md#public-route)).
Caddy keeps the request's `Host` and `Authorization`, caches nothing and flushes each write at once,
and it sets no timeout on a response, so the `/mcp` event stream lasts as long as the client and
impd keep it open.

impd counts its limits per client and grant, never per address, because every request reaches it
from the front. Caddy therefore limits the requests of each client address, and of each IPv6 /64,
and answers 429 past the limit. HTTP/3 stays off, so the front needs no UDP port.

## The tunnels

Both tunnels take their routes from Cloudflare rather than from a file in the cluster, so a route
change is a Pulumi change to a tunnel's configuration, and cloudflared picks it up with no redeploy.
A tunnel's configuration is an ordered list, and cloudflared takes the first rule that matches. Each
list ends with a catch-all that answers 404, so a hostname with no rule of its own, or any other
name that reaches the tunnel, gets a 404 and never a workload. Each rule's pattern matches whole
paths only, so any other path, including a variant of a listed one such as `/login/` or `/LOGIN`,
falls to the catch-all. Each hostname is a proxied CNAME to its tunnel, so it resolves to
Cloudflare's edge and never to the host.

### The shared tunnel

The shared tunnel's cloudflared runs in k3s, in its own namespace, as two replicas that each hold
connections to Cloudflare's edge with the tunnel's token. The tunnel serves while either replica is
connected, so one replica's restart drops no traffic. Its list holds the preview webhook's rule,
which matches the path `/webhook` alone and routes it to the listener on the host's tailnet address,
which the host admits only from pod addresses. It then holds the files service's rule, which has no
path pattern, so every path of `files.geoff.cloud` reaches the service's cluster address and the
service answers 404 for any path it does not serve.

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

## HTTPS and the edge

The zone redirects plain HTTP to HTTPS on every proxied hostname, so a client that names an
`http://` URL is sent to the encrypted one. The TLS front's hostname is not proxied, and the host
keeps port 80 shut, so a plain request to it gets no answer at all. The redirect cannot protect a
bearer token or an authorization code in that first plain request, because the request already holds
it by the time the edge answers. A client must therefore use `https://` URLs from the start; the
redirect is for a client that gets it wrong once.

## Authentication belongs to the workload

The gateway is an OAuth 2.1 issuer and authenticates every MCP call itself, so the tunnel carries
traffic and decides nothing about who may make an MCP call. Its discovery, token and revocation
endpoints and the MCP endpoint must answer a client that has no browser and no Cloudflare login,
which an Access login in front of them would break. Cloudflare Access therefore never fronts the
whole hostname. It fronts only the pages that the owner's browser loads to sign in and approve a
client, which no MCP client calls.

The files service has no Access login either, because GitHub's image proxy fetches each file in a
pull request without one. A read needs only the link, whose random ID nobody can guess, and every
upload, listing, expiry change or removal needs one of the service's two role tokens.

Each public route's registry entry names its auth layer, and the Pulumi program fails on a public
entry without one ([the exposure registry](./firewalls.md#the-exposure-registry)), so a new route
states who authenticates its calls before it can go public.

### The gateway's route boundary

The atc gateway's routes split by caller. The split follows the route table of atc's MCP HTTP
server, and the tunnel and the Access application both read it from one list in the Pulumi program.
A route atc adds later reaches nothing until it joins that list.

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
this edge control reverts the Access resources and the atc tunnel's two gateway rules together, and
leaves atc's own authentication as it is.

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

A new public route is the exception in this estate. A service stays on the host or the tailnet
unless its PR states why it must be public, and the route is then a tunnel rule ahead of the
catch-all and a proxied record for its hostname, reviewed in the same preview. The hostname needs a
public entry in the [exposure registry](./firewalls.md#the-exposure-registry) that names its auth
layer, and the Pulumi program refuses a route to any other hostname. A route that must hold a stream
open longer than Cloudflare's proxy allows goes through the host's TLS front instead, as a
front-route entry, which gives the front its hostname, upstream and paths and Pulumi its DNS
records. impd's tailnet names under `imps.geoff.cloud` never pass through either way in
([imp on the host](../host/imp.md#dns-and-certificates)).
