# cloud

Infrastructure as code for `geoff.cloud`, the owner's private cloud on the tailnet: one Onidel VM
running NixOS, a single-node k3s cluster, and [imp](https://github.com/zgeoff/imp) microVMs on the
host. Pulumi declares every cloud resource and cluster workload, and one NixOS flake declares the
host. The first workload is an agent platform built on imp and [atc](https://github.com/zgeoff/atc),
with atc's MCP endpoint public at `atc.geoff.cloud`.

## Quick start

```bash
bun install
bun run sdk:build
bun run preview   # changes nothing; needs the tailnet and the 1Password `cloud` vault
```

[Development](./docs/runbooks/development.md) covers the tools and the secrets a first preview
needs.

## Checks

```bash
bun run format:check
bun run lint
bun run typecheck
bun run test
bun run test:scripts
```

CI runs the same checks, plus the type-aware lint, gitleaks, the provider's Go checks and the NixOS
checks.

## Layout

- `infra/`: the Pulumi program
- `provider/` and `sdk/onidel/`: the Onidel provider and its generated SDK
- `nixos/`: the host flake
- `images/agent/`: the agent image
- `deploy/atc-gateway/`: the atc gateway's images and restore Job
- `workers/`: the external health-check Worker
- `scripts/`: repo and host tooling

## Documentation

[docs/](./docs/README.md) indexes the architecture and the runbooks.
