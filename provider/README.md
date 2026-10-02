# Onidel Pulumi provider

A partial Pulumi provider for the [Onidel](https://onidel.com) cloud API, written in Go with
`pulumi-go-provider`'s `infer` package. It covers only the resources this repo uses. Pulumi
generates its TypeScript SDK into `sdk/onidel/` as the workspace package `@zgeoff/pulumi-onidel`.

`spec/onidel.yaml` is the OpenAPI 3.0.3 spec the client is written against. `internal/client` is a
small typed HTTP client for the calls the provider makes; `internal/onidel` holds the resources.

## Configuration

| Key        | Notes                                                                                          |
| ---------- | ---------------------------------------------------------------------------------------------- |
| `apiKey`   | Secret. Falls back to `ONIDEL_API_KEY`. The key is in 1Password at `op://cloud/onidel-api/credential`. |
| `teamId`   | Optional. Unset uses the API's default team; `SshKey` needs an explicit team and uses the caller's only team. |
| `endpoint` | Optional. Defaults to `https://api.cloud.onidel.com`.                                           |

## Resources

| Token                       | Updates in place                         | Replaces on change                                     | Import ID              |
| --------------------------- | ---------------------------------------- | ------------------------------------------------------ | ---------------------- |
| `onidel:index:SshKey`       | `name`, `publicKey`                      | nothing                                                | key UUID               |
| `onidel:index:Vm`           | `name`, `ipv6`, `firewallGroupId`        | `location`, `cpu`, `ram`, `disk`, `os`, `snapshotId`, `isoId`, `instanceType`, `paymentCycle`, `sshKeys`, `vpcs`, `startupScriptId`, `disableSshBlocking` | VM UUID |
| `onidel:index:FirewallGroup`| `description`                            | nothing                                                | group UUID             |
| `onidel:index:FirewallRule` | `description`                            | `firewallId`, `protocol`, `port`, `subnet`, `subnetSize` | `<firewallId>/<ruleId>` |
| `onidel:index:Rdns`         | `domain`                                 | `vmId`, `ip`                                           | `<vmId>/<ip>`          |

A firewall group is attached to a VM through the Vm's `firewallGroupId`, which the API models as a
VM setting (`PATCH /vm/{id}` with `firewall_group_id`, or `disable_firewall` to detach).

### Vm notes

- **Root password.** The API returns the VM's root password in plain text in every VM object. The
  client's `VM` type has no field for it, so it is dropped at decode time and never reaches state.
  `TestVMPasswordNeverReachesState` guards this. Never log a VM response body.
- **Import.** `pulumi import onidel:index:Vm geoffcloud <vm-id>` reads `name`, `location`, `cpu`,
  `ram`, `disk`, `ipv6` and `firewallGroupId`, and resolves `os` by matching the VM's template name
  against `GET /os_templates`. The API does not report `instanceType`, `paymentCycle`, `sshKeys`,
  `vpcs`, `snapshotId`, `isoId`, `startupScriptId` or `disableSshBlocking`. When the program sets
  them on an imported VM, they are adopted without a replace. They force a replace only when the
  old and new values are both set and differ.
- **Updates** are one `PATCH` per setting, as the API requires. The provider waits for the VM to be
  `active` with no action in flight before and after each one.
- **Create.** `POST /vm` returns 201 with no body, so the provider finds the new VM by listing: the
  one with the requested name that was not there before. It then waits for `active`.
- **`ipv6`** unset means "leave it as the API has it". `firewallGroupId` unset means "detached".

## Build and regenerate

From the repo root:

```sh
bun run provider:build   # builds provider/bin/pulumi-resource-onidel
bun run provider:check   # gofmt, go vet, go test
bun run sdk:gen          # rebuilds the binary and regenerates sdk/onidel/
bun install              # links the regenerated workspace package
```

`sdk:gen` runs
`pulumi package gen-sdk ./provider/bin/pulumi-resource-onidel --language nodejs --version 0.1.0 --out sdk/.gen`
and moves `sdk/.gen/nodejs` to `sdk/onidel`. Never edit `sdk/onidel/` by hand. The package name,
the exact `@pulumi/pulumi` version and the SDK's dev dependencies come from the provider's schema
language settings in `internal/onidel/provider.go`. Regenerate after any schema change and commit
the result.

## Using it from infra/

The provider is not published, so `infra/` loads the local binary. In `infra/Pulumi.yaml`:

```yaml
plugins:
  providers:
    - name: onidel
      path: ../provider/bin
```

Add the SDK to `infra/package.json` as `"@zgeoff/pulumi-onidel": "workspace:*"`, then:

```ts
import * as onidel from '@zgeoff/pulumi-onidel';

const vm = new onidel.Vm('geoffcloud', { /* ... */ }, { protect: true });
```

Set the key with `pulumi config set --secret onidel:apiKey`, or export `ONIDEL_API_KEY` through
`op run`.

## Known API gaps

- **No block volume calls.** The API cannot create, attach or detach volumes. `geoffcloud`'s `vdb`
  is a manual step.
- **No VM start.** The API has stop and reboot but no start, so the provider never stops a VM.
- **No resize.** `cpu`, `ram` and `disk` cannot change after provisioning, so they replace the VM.
- **OS reinstall.** The API can reinstall a VM's OS in place (`PATCH os_id`). The provider does not
  use it: a changed `os` replaces the VM, which makes the data loss visible in the preview.
- **Unreported fields.** See the import notes above.
- **Previews with unknown inputs.** The Vm's custom diff sees an unknown value (such as the
  `firewallGroupId` of a group created in the same update) as unset, so the preview may omit that
  change. The real update sees the known value and applies it.
