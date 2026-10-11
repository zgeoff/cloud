# Onidel Pulumi provider

A partial Pulumi provider for the [Onidel](https://onidel.com) cloud API, written in Go with pulumi-go-provider's `infer` package. No Pulumi or Terraform provider for Onidel exists, so this one covers only what the repo uses: SSH keys, VMs, firewall groups and their rules, and reverse DNS. Pulumi generates its TypeScript SDK into `sdk/onidel/` as the workspace package `@zgeoff/pulumi-onidel`, which `infra/` imports ([infrastructure as code](../docs/architecture/infrastructure-as-code.md)).

`spec/onidel.yaml` is the OpenAPI spec the client is written against. `internal/client` is the typed HTTP client, and `internal/onidel` holds the resources, with each resource's update and replace rules beside its schema.

## Build and regenerate

From the repo root:

```bash
bun run provider:build   # builds provider/bin/pulumi-resource-onidel
bun run provider:check   # gofmt, go vet, go test
bun run sdk:gen          # rebuilds the binary and regenerates sdk/onidel/
bun install              # links the regenerated workspace package
```

Never edit `sdk/onidel/` by hand. The SDK's package name and dependencies come from the schema's language settings in `internal/onidel/provider.go`, so regenerate after any schema change and commit the result. The provider is not published: `infra/Pulumi.yaml` loads the local binary from `../provider/bin`.

## Configuration

The provider reads its API key from `onidel:apiKey`, or from `ONIDEL_API_KEY`, which `.env` resolves from 1Password through `op run`. It needs no other setting for this repo's stack.

## How it behaves

- **The root password never reaches state.** Onidel returns the VM's root password in every VM object. The client's VM type has no field for it, so decoding drops it, and a test guards that. Never log a VM response body.
- **Most VM inputs replace the VM.** The API cannot resize a VM, and a changed OS replaces it too, although the API could reinstall in place, so the data loss shows in the preview. The repo's VM is protected for that reason.
- **Each update is one call per setting**, as the API requires, and the provider waits for the VM to settle before and after each one.
- **A create finds its VM by listing**, because the create call returns no body.
- **An import adopts unreported fields.** The API never reports some create-time inputs, so an imported VM takes the program's values for them without a replace.
- **Only idempotent calls retry.** Bursts of reads get 503 answers, so GET, PUT and DELETE retry with backoff. POST and PATCH never retry, because a retried create or update could act twice.

## Known API gaps

- No block volume calls, so the host's second disk is a manual step.
- No VM start, so the provider never stops a VM.
- A preview can omit a change whose input is still unknown, such as the firewall group of a group created in the same update. The update itself applies it.
