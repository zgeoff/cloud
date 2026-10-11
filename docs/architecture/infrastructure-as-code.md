# Infrastructure as code

One Pulumi program, in `infra/`, declares every cloud resource and every workload in the k3s
cluster, and one stack, `prod`, holds the live state. Pulumi runs on Bun, and every run reads its
inputs from 1Password through `op run`, so the program sees each secret only for the length of a
run. A run changes nothing until someone applies it, and the guards at the top of the program stop a
run whose inputs would plan a mass delete. [The host](./host/host.md) covers the NixOS host, which
Pulumi does not drive.

## What the program owns

The program composes its resources in one root module, and each provider manages its own part of the
estate:

| Provider                | Manages                                                                    |
| ----------------------- | -------------------------------------------------------------------------- |
| Onidel, this repo's own | the VM and the cloud firewall outside it                                   |
| Cloudflare              | the tunnel and its routes, the zone's HTTPS redirect, the Worker, R2       |
| Tailscale               | the whole tailnet policy file, and the auth keys that tagged nodes join by |
| Kubernetes              | every workload in k3s, through the cluster's API on the tailnet            |

One Pulumi preview covers all four, so a change to a route, a grant and the workload behind them
reviews as one diff.

No Pulumi or Terraform provider for Onidel exists, so the repo builds a partial one in Go with
pulumi-go-provider's `infer` package and generates its TypeScript SDK
([the provider README](../../provider/README.md)). Onidel's API has no calls for block volumes, so
the VM's second disk was added by hand and the provider never sees it. The VM itself was made by
hand and imported, and almost every input replaces it, so the program protects it and keeps it on a
delete: a typo in its inputs fails the preview instead of destroying the host.

The program writes one value back outside Pulumi. imp's reusable tailnet key, which imp's dev
instances join by, is minted by Pulumi and copied into its 1Password item on each new key, so the
item always holds the live key.

## What the program never owns

- **The host's configuration.** The NixOS flake owns it, and a host switch applies it
  ([the host](./host/host.md)).
- **impd's DNS records.** impd writes the records for its own hostnames and its ACME challenges at
  run time, so a Pulumi declaration of them would fight impd on every apply
  ([imp on the host](./host/imp.md#dns-and-certificates)).
- **The owner's PC.** The gateway dials the PC's daemon over the tailnet, and the policy names the
  PC by address, but nothing here configures it.

## State and drift

Pulumi keeps its state in an R2 bucket and encrypts each secret in it with a passphrase from
1Password. The state therefore holds the secrets Pulumi generated, such as Grafana's admin password,
and only the passphrase opens them; replacing the passphrase would strand every secret in the state.

Drift is any difference between the live resources and the code. The drift check is a preview that
refreshes from the live APIs first and fails on any change, so it passes only against the revision
that was last applied. A clean `main` passes only when every merged change is applied, because a
merged change nobody has applied yet reads as drift too. An apply is therefore bracketed: a drift
check from the last applied revision proves the baseline, a refreshed preview from the new `main`
shows only the reviewed changes, and a second drift check proves the apply landed. The check runs by
hand, because Onidel offers only full-account API keys and a scheduled CI job would hold one.

Some resources are declared to avoid drift on their own. The host's auth keys are single-use, so
after the host joins they read as used, and the program never mints them again until a reinstall
replaces them on purpose. A Service that the host dials by its cluster address pins that address and
ignores later changes to it, so a refresh never reads it as drift
([1Password Connect](./workloads/onepassword-connect.md)).

## Guards

A missing input can read as "this subsystem is gone", and Pulumi would then plan to delete it. The
program therefore checks every input that decides whether a subsystem exists before any resource
registers, and throws instead:

- **The cluster mode.** The stack config states whether the cluster is managed. An unset mode fails
  the run, and a managed cluster with no kubeconfig fails it too, because otherwise a run outside
  `op run` would plan to delete every cluster resource.
- **Connect's credentials.** A managed cluster needs the Connect server's credentials, as non-empty
  JSON, for the same reason, and the error never holds the value.
- **The gateway's inputs.** With the gateway configured, each daemon needs a valid name, address, ID
  and bearer token, the default daemon must be one of them, and the image must be a real release
  rather than the test stand-in. The preview fails and names the input, so a bad value never reaches
  a pod that crash-loops ([the atc gateway](./workloads/atc-gateway.md)).
- **The gateway's backup.** Its backup inputs are all set or all unset. A partial set fails the run,
  because a silent drop of the backup job would read as success.
- **The alert webhook.** Discord alerts turned on with no webhook fail the run, so the flag never
  deploys an Alertmanager that sends nothing.

The guards fail closed, so the one setting that removes a subsystem on purpose is an explicit one: a
cluster mode of `none` plans the delete of every cluster resource, and nothing in the program sets
it.
