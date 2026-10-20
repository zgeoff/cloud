# Development

This page sets up a machine to work on geoff.cloud, and ends with a preview of the live stack.

## Prerequisites

| Tool                      | Version or source                        | Used for                                                                           |
| ------------------------- | ---------------------------------------- | ---------------------------------------------------------------------------------- |
| Bun                       | `.bun-version`                           | every root script, and the Pulumi program's runtime                                |
| Go                        | `provider/go.mod`                        | building the Onidel provider, which every preview builds                           |
| Pulumi CLI                | `@pulumi/pulumi` in `infra/package.json` | `preview`, `up`, `drift`, stack config, `sdk:gen`                                  |
| 1Password CLI (`op`)      | with a token for the `cloud` vault       | resolving `.env`                                                                   |
| Tailscale                 | the PC (`home-pc`)                       | the k3s API (the PC only), Grafana (any member), SSH to `root@geoffcloud` (admins) |
| Docker                    | current                                  | NixOS builds and switches (`nixos/nix` image), fixture test                        |
| gitleaks                  | on `PATH`                                | the pre-commit hook                                                                |
| `jq`, `gh`, `ssh`, `curl` | current                                  | the scripts in `scripts/`                                                          |

You need no local Nix: every Nix command here runs in the `nixos/nix` image.

## Install

```sh
git clone https://github.com/zgeoff/cloud.git
cd cloud
bun install
```

`bun install` also installs the lefthook git hooks. pre-commit fixes and checks staged files and
runs gitleaks. pre-push runs the format check, lint, the Pulumi pin check, typecheck, the tests, the
dead-code check, the provider's checks and the SDK check; CI adds the type-aware lint, the script
tests, the docs checks and the NixOS checks.

The Pulumi CLI runs at the version `infra/package.json` pins for `@pulumi/pulumi`, the one Pulumi
pin in the repo. CI installs that version for the SDK check, and `check:sdk` warns when the local
CLI differs, because another CLI version can generate a different SDK.

## Secrets

The repo is private, but it is treated as public, so it holds no secret. Every deployment input
lives in the 1Password vault `cloud`. Some secrets live elsewhere: see
[secrets](../architecture/secrets.md). The committed `.env` holds only `op://` references, and each
command that needs them runs through `op run`:

```sh
op run --env-file=.env -- <command>
```

The root scripts `preview`, `drift` and `up` already do this. `op` needs a service-account token
that can read the `cloud` vault, in `OP_SERVICE_ACCOUNT_TOKEN`. `.env` names each variable and its
1Password item.

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

   It refreshes from the live APIs and exits non-zero on any change. On a clean `main` that is fully
   applied, expect 0 changes; a merged change that nobody has applied yet also fails it.

Both need the tailnet: the program reaches the k3s API at `https://geoffcloud:6443`. The tailnet
policy opens that port to the PC (`home-pc`) and the prod apply job's runner only, so run both from
the PC.

## Check the host

Tailscale SSH authenticates admins as root on `tag:cloud` hosts:

```sh
ssh root@geoffcloud k3s kubectl get nodes
```

## Next

- [The architecture overview](../architecture/overview.md): what runs where, and why.
- [Workflows](./workflows.md): how to change things.
