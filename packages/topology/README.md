# @zgeoff/cloud-topology

The values that geoff.cloud's host, Pulumi program, scripts and image builds share live here, in
`constants.json`: the VM's ID and public addresses, the tailnet's range, tags and node addresses,
k3s's ranges and ports, Podman's bridge that imp-host runs on, and the ports and addresses of atc,
impd and 1Password Connect. Each value has one written source: change it in this file, and every
reader that can read the file picks up the change from the same commit. The few copies that cannot
read it are listed below, with the check that holds them to the file.

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

Keep version pins out of this package: each keeps its own pin file, which its bump tooling rewrites.
Put other data that the host, infra and the scripts all read in this package, as its own file beside
`constants.json`. Put a schema here too for data that infra hands to a script, such as the payload
of the Job that adds nixie's sandbox images, so the producer and the parser share one type.

## The exposure registry

`exposure.json` holds every public route and port, and each port the host keeps to the tailnet or to
itself, with its scope and its reason. The package exports it parsed as `exposure`, and fails to
load when one of its ports differs from the same port in the constants. The host reads it through
`nixos/exposure.nix`, nixie's ingress takes its port from it, and `bun run docs:exposure` writes its
table into `docs/reference/exposure.md`. For the checks that hold it to the code, see
[Firewalls](../../docs/architecture/network/firewalls.md#the-exposure-registry).
