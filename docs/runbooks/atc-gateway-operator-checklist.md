# atc-gateway: operator checklist

The ordered steps from the validated package to a running gateway and cloud daemon. Each step names
what it waits on, the approval it needs, and its effect. "Approval" means Geoff's yes to that exact
step; nothing here is approved by default. Steps marked **upstream** wait on atc or imp work that
does not exist yet.

Current state (2026-10-03): A1 is done: geoffcloud runs imp 0.20.0 (system-7, a2c5fdb), with impd
healthy, the Firecracker jailer on, `inet imp-forward` live and k3s unchanged. A copy of impd's
0.17.0 database is in `/root/imp-db-backups/` on the host, for a rollback to `system-6`. B3 has run
once, ahead of B2, with the 2.10.0 stand-in binary (run 37044948105). C3's R2 bucket, key and restic
password exist in 1Password; C4's GitHub token exists, unused. Nothing else below has run.
Published, both public:

- `ghcr.io/zgeoff/atc-gateway:2.10.0@sha256:86cd2af8f297cb5143cee19e71b921d6ba0bc3e3a004d6498be7533b34a068be`
  **FIXTURE STAND-IN, NOT USABLE AS THE PRODUCTION GATEWAY.** It holds atc 2.10.0's `atc` binary.
  `infra/load-atc-gateway-inputs.ts` refuses it.
- `ghcr.io/zgeoff/atc-gateway-backup:2.10.0@sha256:cc9d89b9f72fdc8ee0f209e101031e8d3f7620e3a527cfc2608c57d143977c6d`
  (restic and sqlite3; usable as is, and pinned in `restore-job.yaml`)

B3 runs again after B2 to publish the real gateway image. The package is validated locally:

| Check                                                                                                                                                                                                | Result                               |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| `scripts/test-atc-gateway-fixture.sh`: images build from the pinned, checksum-verified binary; nonroot on a read-only root; Host rule; OAuth state survives a restart and a backup, wipe and restore | pass (local and CI)                  |
| `bun run preview` with `atcGateway` unset                                                                                                                                                            | no change                            |
| `bun run preview` with `atcGateway` set (scratch config file)                                                                                                                                        | creates only the 9 gateway resources |
| `nix build ./nixos#checks.x86_64-linux.atc-daemon`                                                                                                                                                   | builds                               |
| geoffcloud's system with the flake changes                                                                                                                                                           | unchanged                            |
| `deploy/atc-gateway/restore-job.yaml`, client dry run                                                                                                                                                | valid                                |

The fixture uses atc 2.10.0's `atc mcp --http` as a stand-in for the gateway binary. It does not
prove gateway-to-daemon transport, `/healthz` and `/readyz`, R2, or anything in k3s.

## Two access choices for approval

Neither is applied. Each needs an explicit yes to the exact statement below.

| Choice                    | Source                                         | Destination                                | Port     | Auth beyond the network                                     | Effect                                                                          |
| ------------------------- | ---------------------------------------------- | ------------------------------------------ | -------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------- |
| D1: impd grant            | `tag:cloud` (geoffcloud, pods included)        | `tag:imp` (impd, `imp-geoffcloud`)         | tcp 7070 | impd token `atc-cloud`: scope manage, `harness-*` imps only | one grant added to the tailnet policy; no access removed; preview diff reviewed |
| E2: cloud daemon listener | today `autogroup:member` (every member device) | geoffcloud's tailnet address, `atc-daemon` | tcp 8415 | per-daemon bearer token (gateway → daemon)                  | a new listener on the tailnet only; the edge firewall keeps it off the internet |

The gateway pod reaches the daemon on the same host, so E2 needs no new grant. Narrowing who can
reach 8415 (a grant from `tag:cloud` only, in place of members) is optional and can follow.

## A. Maintenance, independent of the gateway

| #   | Step                                                                                                                                           | Waits on        | Approval                                            | Effect                                                                                                                                                                                                                                                                                                                                                                                              |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------- | --------------- | --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | Merge branch `imp-0.17` and `nixos-rebuild switch` geoffcloud. First `imp ls` on the host, and `imp sleep` each awake imp (none on 2026-10-03) | nothing (built) | yes: it changes live forward rules and restarts imp | imp-host goes from 0.12.0 (the `:latest` it pulled on 2026-10-02) to 0.17.0, with module and image both pinned by digest (imp#109 tracks the module's `:latest` default); impd runs 4 additive migrations at start, with no manual step; a few minutes of imp downtime; the docker0 → k3s deny moves into imp's `imp-forward` table, same effect; k3s keeps running; rollback: switch to `system-5` |
| A2  | imp #90 (orphan-cleanup safety) and leases (#96, 0.15.0) on the host                                                                           | in 0.17.0       | covered by A1                                       | no manual state migration                                                                                                                                                                                                                                                                                                                                                                           |

## B. Build and publish

| #   | Step                                                                                                                                                                                                                           | Waits on                     | Approval                                           | Effect                                                     |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------- | -------------------------------------------------- | ---------------------------------------------------------- |
| B1  | **upstream** atc releases `atc-gateway` (linux-x64) with SHA256SUMS                                                                                                                                                            | atc's gateway PR and release | none for cloud                                     | the artifact exists                                        |
| B2  | Update `deploy/atc-gateway/versions.env` (release, asset `atc-gateway-linux-x64`, checksum); fill args, `/healthz`, `/readyz` and env var names into the stack config template; rerun the fixture test against the real binary | B1, atc's interface notes    | none (repo work)                                   | the package tracks the real gateway                        |
| B3  | Run the `atc-gateway images` workflow with `push: true`                                                                                                                                                                        | B2                           | yes: publishes two public images to ghcr.io/zgeoff | free; public image of a public binary; record both digests |

## C. Credentials (1Password `cloud` vault)

| #   | Step                                                                                                           | Waits on           | Approval                                                  | Effect                                                                                                                      |
| --- | -------------------------------------------------------------------------------------------------------------- | ------------------ | --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| C1  | Bearer token for the cloud daemon (gateway → daemon)                                                           | atc's token format | yes                                                       | new secret; goes to the gateway Secret and the daemon's credential file                                                     |
| C2  | impd token `atc-cloud`: `imp token new atc-cloud --scope manage --imps 'harness-*'`                            | none               | yes                                                       | the daemon can create, wake and destroy `harness-*` imps only, never `--net`                                                |
| C3  | Backup: restic password, and either a new R2 bucket with its own key or the existing `geoff-cloud-backups` key | none               | yes, and pick narrow (new bucket) or broad (existing key) | a new bucket is free within the R2 allowance (about 2.6 GB of the 10 GB free storage left account-wide, checked 2026-10-03) |
| C4  | GitHub token for imp's broker, if harness imps self-clone                                                      | the clone decision | yes: whose account, which repos, read-only                | broker injects HTTPS git auth; the guest sees a placeholder                                                                 |

## D. Access

| #   | Step                                                                                       | Waits on        | Approval           | Effect                                                                                        |
| --- | ------------------------------------------------------------------------------------------ | --------------- | ------------------ | --------------------------------------------------------------------------------------------- |
| D1  | Tailnet grant `tag:cloud → tag:imp:7070`                                                   | none            | yes: policy change | geoffcloud (all of it, including pods) can reach impd's API; the token from C2 still gates it |
| D2  | Later, for a daemon off geoffcloud: `tag:atc-daemon` and `tag:cloud → tag:atc-daemon:8415` | a second daemon | yes                | not needed for the cloud daemon                                                               |

## E. Deploy

| #   | Step                                                                                                                                                               | Waits on       | Approval                            | Effect                                                                                                                                                                    |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| E1  | **upstream** atc's daemon tailnet listener                                                                                                                         | atc            | none for cloud                      | the daemon command and flags exist                                                                                                                                        |
| E2  | Enable `services.atc-daemon` on geoffcloud (import `nixosModules.atc-daemon`, set args, token files); `nixos-rebuild switch`                                       | E1, C1, C2, D1 | yes: new listener, tailnet tcp 8415 | `tailscale0` is a trusted interface, so the tailnet policy alone gates who reaches 8415 (today: members, through `autogroup:member → *`); the bearer token gates the rest |
| E3  | Set the `atcGateway` stack config (image digests from B3, public URL, daemons), add the `ATC_GATEWAY_*` references to `.env`, `bun run preview`, then `bun run up` | B3, C1, C3     | yes: live deploy                    | creates the 9 gateway resources; no public route yet; OAuth state starts accruing on the root disk (in later Onidel snapshots)                                            |
| E4  | Restore test: back up, restore into a scratch claim, start a scratch gateway on it, check its clients                                                              | E3             | none beyond E3                      | proves the R2 path; record it in an issue                                                                                                                                 |

## F. Public route and cutover

| #   | Step                                                                                                                                                                                                                                              | Waits on | Approval                            | Effect                                                                |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | ----------------------------------- | --------------------------------------------------------------------- |
| F1  | `atc.geoff.cloud`: proxied CNAME to the existing tunnel, and a tunnel ingress to `http://atc-gateway.atc.svc.cluster.local:8414` before the 404 catch-all; health-check target `https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp` | E3       | yes: DNS and public exposure        | free; the gateway is reachable from the internet behind its own OAuth |
| F2  | **upstream** OAuth issuer move to `https://atc.geoff.cloud`; clients re-register                                                                                                                                                                  | F1, atc  | yes: access change for every client | existing grants end; clients sign in again                            |
| F3  | Retire the PC origin for `mcp.geoff.cloud` (redirect or remove)                                                                                                                                                                                   | F2       | yes                                 | one public MCP origin                                                 |

## G. Harness smoke test

| #   | Step                                                                                                           | Waits on                        | Approval            | Effect                                                                                             |
| --- | -------------------------------------------------------------------------------------------------------------- | ------------------------------- | ------------------- | -------------------------------------------------------------------------------------------------- |
| G1  | **upstream** harness image in the atc repo, built on the host with `imp image build`                           | atc                             | none for cloud      | the image exists on geoffcloud                                                                     |
| G2  | **upstream** harness login method                                                                              | the separate integration review | yes                 | open                                                                                               |
| G3  | imp's generic leases (`leases.acquire/renew/release/list`)                                                     | A1 (0.17.0 ships them)          | covered by A1       | owned leases (`exec` scope; the `atc-cloud` token's `manage` covers it) instead of the shared hold |
| G4  | Smoke: the gateway starts a harness in a fresh `harness-smoke-*` imp, its output is read, the imp is destroyed | E2, E3, G1–G3                   | yes: first live run | the first end-to-end evidence; until then, the deployment is unproven                              |

## Deferred, not dropped

- A Tailscale sidecar giving the gateway pod its own `tag:atc-gateway`, once a second daemon exists.
- The PC daemon and `tag:atc-daemon` (D2).
- An encryption and backup design for impd's state on the pool.
- atc's approvals (#144, deferred), session migration (#145, stretch) and modularisation (#147,
  later).
