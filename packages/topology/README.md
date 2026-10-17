# @zgeoff/cloud-topology

The values that geoff.cloud's host, Pulumi program, scripts and image builds share live here, in
`constants.json`: the VM's ID and public addresses, the tailnet's range, tags and node addresses,
k3s's ranges and ports, and the ports and addresses of atc, impd and 1Password Connect. Each value
has one written source, so a change to one is a change to this file, and every reader picks it up
from the same commit.

## Readers

Each part of the repo reads the file in its own language:

| Reader                | Reads it through                                                      |
| --------------------- | --------------------------------------------------------------------- |
| `infra/` and TS tools | the package's typed `topology` export, checked against its zod schema |
| `nixos/`              | `builtins.fromJSON`, in `nixos/topology.nix`                          |
| shell scripts         | jq, with the path from the script's own directory                     |
| the atc gateway image | a build arg that the build scripts read with jq                       |

The host reads a file outside `nixos/`, so the flake builds with the repo root as its source
(`path:.?dir=nixos`). The switch script and the NixOS checks both build that way, and a change here
counts as an input of the NixOS checks.

## Copies that stay outside

A few copies cannot read the file: the stack config's daemon addresses, which the atc gateway's
registry takes as config, and the tailnet tag that the deploy workflow passes to an action. nixie's
config file holds no copy, because infra builds its `imp` section from the constants.
`bun run check:topology` compares each copy with the constants and fails on a mismatch. It runs in
CI and before a push.

Version pins are not topology: each keeps its own pin file, which its bump tooling rewrites. Other
data that the host, infra and the scripts all read belongs in this package as its own file beside
`constants.json`.

## The exposure registry

`exposure.json` lists every public route and port, and each port the host keeps to the tailnet or to
itself, with its scope and its reason. The package exports it parsed as `exposure`, and fails to
load when one of its ports differs from the same port in the constants. The host reads it through
`nixos/exposure.nix`, nixie's ingress takes its port from it, and `bun run docs:exposure` writes its
table into `docs/reference/exposure.md`.
[Firewalls](../../docs/architecture/network/firewalls.md#the-exposure-registry) covers the checks
that hold it to the code.
