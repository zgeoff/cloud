# cloud

Infrastructure as code for `geoff.cloud`, Geoff's general-purpose private cloud on the tailnet:
today one Onidel VM running a single-node k3s cluster, with imp microVMs on the host as the first
workload. `docs/architecture.md` is the design; issue #1 tracks the work.

## Layout

Bun workspace. `infra/` is the Pulumi program (TypeScript, Bun runtime). `provider/` is the partial
Onidel Pulumi provider, a Go module built with `pulumi-go-provider`'s `infer` package. `sdk/onidel/`
is its generated TypeScript SDK: never edit it by hand, regenerate it. `nixos/` is the host flake.
`docs/` holds the architecture and runbooks. `scripts/` holds repo tooling.

## Rules

- Commits go straight to `main` for this repo; Geoff authorised that on 2026-10-02.
- This repo is public. Never commit a secret. Secrets live in the 1Password `cloud` vault; `.env`
  holds only `op://` references, resolved with `op run --env-file=.env -- <command>`.
- Never print a secret, and never log a whole Onidel VM object: the API returns the root password.
- No live change without a preview first. The Tailscale policy file in particular: Pulumi's `Acl`
  replaces the whole file, so Geoff reviews the diff before an apply that changes it.
- The host's nftables rules live in the table `inet cloud_host`. Never `flush ruleset`: imp owns
  `inet imp_host` and `inet imp_egress`.
- Never touch `/dev/vdb` on the host. It holds imp's ZFS pool.
- Everything the hooks and CI run is a root `package.json` script.

## Project management

Geoff runs this project through a delegated coordinating agent, which reaches sessions through atc
(2026-10-03). Its word is Geoff's sign-off; Geoff is the final rubber stamp.

- Escalate anything you doubt through the coordinating agent; it brings Geoff in directly.
- Before an action that costs money, deletes data or cannot be undone, state its exact effect back
  to it and act only on its approval of that statement, not of a summary.
- A permission-check block needs Geoff himself. Tell the coordinating agent, so it can bring him in.
