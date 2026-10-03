# Getting started

This page sets up a machine to work on geoff.cloud, and ends with a preview of the live stack.

## Prerequisites

| Tool                      | Version or source                  | Used for                                                    |
| ------------------------- | ---------------------------------- | ----------------------------------------------------------- |
| Bun                       | `.bun-version` (1.4.2)             | every root script, and the Pulumi program's runtime         |
| Go                        | `provider/go.mod` (1.26.6)         | building the Onidel provider, which every preview builds    |
| Pulumi CLI                | current                            | `preview`, `up`, `drift`, stack config                      |
| 1Password CLI (`op`)      | with a token for the `cloud` vault | resolving `.env`                                            |
| Tailscale                 | a member device of the tailnet     | the k3s API, Grafana, and SSH to `root@geoffcloud`          |
| Docker                    | current                            | NixOS builds and switches (`nixos/nix` image), fixture test |
| gitleaks                  | on `PATH`                          | the pre-commit hook                                         |
| `jq`, `gh`, `ssh`, `curl` | current                            | the scripts in `scripts/`                                   |

You need no local Nix: every Nix command here runs in the `nixos/nix` image.

## Install

```sh
git clone https://github.com/zgeoff/cloud.git
cd cloud
bun install
```

`bun install` also installs the lefthook git hooks. pre-commit fixes and checks staged files and
runs gitleaks. pre-push runs the same checks as CI.

## Secrets

The repo is public, so it holds no secret. Every secret lives in the 1Password vault `cloud`. The
committed `.env` holds only `op://` references, and each command that needs them runs through
`op run`:

```sh
op run --env-file=.env -- <command>
```

The root scripts `preview`, `drift` and `up` already do this. `op` needs a service-account token
that can read the `cloud` vault, in `OP_SERVICE_ACCOUNT_TOKEN`. [The reference](./reference.md#env)
lists each variable and its 1Password item.

Never print a resolved value. Never log a whole Onidel VM object: the API returns the VM's root
password in it.

## First preview

The Pulumi program lives in `infra/`, with one stack, `prod`. Its state lives in Cloudflare R2;
`PULUMI_BACKEND_URL` in `.env` points at it.

1. Build the generated Onidel SDK, then preview:

   ```sh
   bun run sdk:build
   bun run preview
   ```

   `preview` builds the provider binary, then runs `pulumi preview --stack prod` inside `op run`. It
   changes nothing.

2. Check for drift between the code and the live resources:

   ```sh
   bun run drift
   ```

   It refreshes from the live APIs and exits non-zero on any change. On a clean `main`, expect 0
   changes.

Both need the tailnet: the program reaches the k3s API at `https://geoffcloud:6443`.

## Check the host

Tailscale SSH authenticates admins as root on `tag:cloud` hosts:

```sh
ssh root@geoffcloud k3s kubectl get nodes
```

## Next

- [Architecture](./architecture.md): what runs where, and why.
- [Workflows](./workflows.md): how to change things.
