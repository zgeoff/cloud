# cloud

Infrastructure as code for `geoff.cloud`, Geoff's general-purpose private cloud on his tailnet.
Today it is one Onidel VM, `geoffcloud`, running NixOS with a single-node k3s cluster. Pulumi
manages every cloud resource. The first workload is an agent platform built on
[imp](https://github.com/zgeoff/imp) and [atc](https://github.com/zgeoff/atc).

## Documentation

| Page                                                         | Read it to                                                         |
| ------------------------------------------------------------ | ------------------------------------------------------------------ |
| [Getting started](./docs/getting-started.md)                 | set up the tools and secrets, and run a first preview              |
| [Architecture](./docs/architecture.md)                       | understand the host, k3s, imp, the tailnet, ingress and monitoring |
| [Workflows](./docs/workflows.md)                             | change infrastructure, switch the host, upgrade imp, observe       |
| [Reference](./docs/reference.md)                             | look up scripts, config keys, secrets, paths, ports and alerts     |
| [Troubleshooting](./docs/troubleshooting.md)                 | fix a known failure                                                |
| [Reinstall runbook](./docs/runbooks/reinstall-geoffcloud.md) | reinstall the host as NixOS                                        |
| [Restore runbook](./docs/runbooks/restore-geoff-cloud.md)    | recover imps, impd's database, the host or the cluster             |
| [atc gateway plan](./docs/plans/atc-gateway.md)              | follow the pending atc gateway deploy                              |
| [Onidel provider](./provider/README.md)                      | work on the Pulumi provider for Onidel                             |

## Status

Live:

- `geoffcloud` on NixOS, with k3s, imp in its `imp-host` container, and tailnet SSH. Public SSH is
  closed.
- The Cloudflare tunnel. `mcp.geoff.cloud` routes to atc's MCP on Geoff's PC.
- imps over HTTPS on the tailnet at `<name>.imps.geoff.cloud`.
- Prometheus, Alertmanager, Loki, Grafana and Alloy in k3s, and the external health check.

**PENDING** (not deployed):

- The atc gateway at `atc.geoff.cloud/mcp`, and the atc daemon on `geoffcloud`. The package is built
  and validated; see [the plan](./docs/plans/atc-gateway.md).
- Public connector sign-in through the gateway's OAuth issuer.
- `imp.geoff.cloud/mcp`, imp's public MCP endpoint.
- Discord delivery of in-cluster alerts. It is built but off.
- A scheduled drift check in CI (#19). It is parked: run `bun run drift` by hand instead.

The [tracking issue](https://github.com/zgeoff/cloud/issues/1) lists the remaining work.
