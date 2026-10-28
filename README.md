<div align="center">
  <h1>cloud</h1>

  <p>
    <a href="https://github.com/zgeoff/cloud/actions/workflows/ci.yml"><img src="https://github.com/zgeoff/cloud/actions/workflows/ci.yml/badge.svg" alt="CI workflow status"></a>
    <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
  </p>

  <p>
    <a href="./docs/README.md">Documentation</a> •
    <a href="./docs/architecture/overview.md">Architecture overview</a> •
    <a href="./docs/runbooks/development.md">Development setup</a>
  </p>
</div>

The infrastructure for `geoff.cloud`, a private cloud on a tailnet.

One Onidel VM runs NixOS, k3s and [imp](https://github.com/zgeoff/impz), and hosts coding agents
that [atc](https://github.com/zgeoff/atc) runs, each session in its own imp. Pulumi manages the
cloud resources and the cluster, and a NixOS flake manages the host.

## Quick start

Set up the tools and secrets that the development setup lists, then run:

```bash
bun install
bun run sdk:build
bun run preview   # changes nothing; needs the tailnet and the 1Password `cloud` vault
```

## Checks

```bash
bun run format:check
bun run lint
bun run typecheck
bun run test
bun run test:scripts
```

CI runs these plus the type-aware lint, gitleaks, the Go checks and the Docker-based linters. The
NixOS checks run nightly and gate the host switch.

## Layout

- `infra/`, `nixos/`: the Pulumi program and the host flake
- `provider/`, `sdk/onidel/`: the Onidel Pulumi provider and its generated SDK
- `packages/`: the shared topology constants and the preview and files services
- `images/`, `deploy/`: the container images and the cluster's workload manifests
- `workers/`: the external health-check Worker
- `scripts/`: repo and host tooling

## Documentation

[docs/](./docs/README.md) covers the architecture and the runbooks.
