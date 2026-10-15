# Public ingress

The estate has one way in from the internet: a Cloudflare tunnel that cloudflared holds open from
inside the cluster. The host opens no inbound port for it, so a public route exists only as a rule
in the tunnel's configuration and a DNS record that points at the tunnel, and Pulumi declares both.
Each workload behind the tunnel brings its own authentication. The tunnel has two routes:
`atc.geoff.cloud`, the atc gateway, which runs its own OAuth server, and
`preview-webhook.geoff.cloud`, the preview service's webhook listener, which checks the signature of
every GitHub delivery. [The atc gateway](../workloads/atc-gateway.md) and
[the preview service](../workloads/preview.md) cover what answers behind each route.

## The tunnel

cloudflared runs in k3s, in its own namespace, as two replicas that each hold connections to
Cloudflare's edge with the tunnel's token. The tunnel serves while either replica is connected, so
one replica's restart drops no traffic. The tunnel takes its routes from Cloudflare rather than from
a file in the cluster, so a route change is a Pulumi change to the tunnel's configuration, and
cloudflared picks it up with no redeploy.

The tunnel's configuration is an ordered list, and cloudflared takes the first rule that matches.
The list holds the gateway's hostname, routed to the gateway's Service in the cluster, then the
preview webhook's hostname, and then a catch-all that answers 404. The webhook's rule matches the
path `/webhook` alone and routes it to the listener on the host's tailnet address, which the host
admits only from pod addresses. The catch-all stays last, so a hostname with no rule of its own, a
request to the webhook's hostname on any other path, or any other name that reaches the tunnel, gets
a 404 and never a workload. Each hostname is a proxied CNAME to the tunnel, so it resolves to
Cloudflare's edge and never to the host.

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

Cloudflare Access never fronts the gateway's hostname. The gateway is an OAuth 2.1 issuer, and its
discovery, authorization, token and registration endpoints must answer a client that has not signed
in yet, which a login wall in front of them would break. The gateway authenticates every MCP call
itself, so the tunnel carries traffic and decides nothing about who may make it.

## Adding a route

A new public route is the exception in this estate. A service stays on the host or the tailnet
unless its PR states why it must be public, and the route is then a tunnel rule ahead of the
catch-all and a proxied record for its hostname, reviewed in the same preview. The hostname needs a
public entry in the [exposure registry](./firewalls.md#the-exposure-registry), and the Pulumi
program refuses a route to any other hostname. `imp.geoff.cloud` has a reserved entry, held free for
imp's own public endpoint, and impd's tailnet names under `imps.geoff.cloud` never pass through the
tunnel ([imp on the host](../host/imp.md#dns-and-certificates)).
