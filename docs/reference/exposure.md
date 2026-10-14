# Exposure

Every public route and port of the estate, and each port the host keeps to the tailnet or to itself,
from the exposure registry in `packages/topology/exposure.json`. `bun run docs:exposure` writes the
table below from the registry, and `bun run check:topology` fails when the two differ.
[Firewalls](../architecture/network/firewalls.md#the-exposure-registry) covers what each scope means
and which checks hold each kind of entry to the code.

<!-- exposure:start -->

| Name                        | Kind               | Exposes                       | Scope    | Reason                                                                                                                                                  | Ticket  |
| --------------------------- | ------------------ | ----------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `tailscale`                 | host-port          | udp 41641                     | public   | WireGuard's direct-connection port: tailnet peers reach the host directly instead of through a DERP relay                                               |         |
| `icmp`                      | host-port          | icmp                          | public   | Path MTU discovery needs ICMP fragmentation-needed and ICMPv6 packet-too-big, and ping checks that the host is reachable                                |         |
| `ssh`                       | host-port          | tcp 22                        | tailnet  | OpenSSH and Tailscale SSH, over the tailnet only: the host keeps 22 shut on its public interface, and the edge drops it once the host is on the tailnet | GEO-420 |
| `atc-daemon`                | host-port          | tcp 8415 on `cni0`            | host     | The atc gateway's pod dials the daemon on the host's tailnet address, and inet cloud_host admits only pod addresses on cni0                             |         |
| `onepassword-connect-relay` | host-port          | tcp 18081 on `docker0`        | host     | imp-host's containers reach 1Password Connect through the host's relay, which inet cloud_host admits from docker0's subnet only                         |         |
| `grafana`                   | host-port          | tcp 30300                     | tailnet  | Grafana's NodePort, which k3s binds to the tailnet range only                                                                                           |         |
| `atc-gateway`               | tunnel-hostname    | `atc.geoff.cloud`             | public   | The atc gateway's MCP and OAuth endpoints for remote MCP clients; the gateway authenticates every call itself                                           |         |
| `imp`                       | tunnel-hostname    | `imp.geoff.cloud`             | reserved | Held for imp's own public MCP route: the /mcp and OAuth paths only, once imp has an OAuth boundary of its own                                           |         |
| `tailnet-funnel`            | tailnet-capability | node attribute `funnel`       | public   | Every member device may publish a local port to the internet through Tailscale Funnel; the grant has no recorded reason                                 | GEO-425 |
| `health-check-workers-dev`  | worker-url         | `health-check` on workers.dev | closed   | The health-check Worker runs on its cron only, so its workers.dev subdomain is disabled                                                                 |         |

<!-- exposure:end -->
