# cloud

**cloud** is the infrastructure for `geoff.cloud`, a private cloud on a tailnet.

One Onidel VM runs NixOS, k3s and [imp](https://github.com/zgeoff/imp), and hosts coding agents:
[atc](https://github.com/zgeoff/atc) runs each session in its own imp, and assistants reach atc
through one public endpoint. Pulumi manages the cloud resources and the cluster, and a NixOS flake
manages the host.

## Quick start

```bash
bun install
bun run sdk:build
bun run preview   # changes nothing; needs the tailnet and the 1Password `cloud` vault
```

The [development runbook](./docs/runbooks/development.md) covers the tools and secrets you need
first.

## Checks

```bash
bun run format:check
bun run lint
bun run typecheck
bun run test
bun run test:scripts
```

CI runs these plus the type-aware lint, gitleaks, the Go checks and the NixOS checks.

## Layout

- `infra/`: the Pulumi program
- `provider/`, `sdk/onidel/`: the Onidel Pulumi provider and its generated SDK
- `nixos/`: the host flake
- `images/agent/`: the image agent sessions run on
- `deploy/atc-gateway/`: the atc gateway's images
- `workers/`: the external health-check Worker
- `scripts/`: repo and host tooling

## Documentation

[docs/](./docs/README.md) covers the architecture and the runbooks.
