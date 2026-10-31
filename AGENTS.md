# Agent Guidelines

Infrastructure as code for `geoff.cloud`, the owner's general-purpose private cloud on the tailnet:
one Onidel VM running a single-node k3s cluster, with imp microVMs on the host as the first
workload. `docs/architecture/overview.md` describes the system, and Linear holds the planned work.

## Required reading

The rules a task needs are not repeated here. Load the skill for the work before starting it.

| Skill                | Load before                                                                        |
| -------------------- | ---------------------------------------------------------------------------------- |
| `code-style`         | writing, reviewing, or renaming any TypeScript — the shared function-verb taxonomy |
| `project-code-style` | the same, beside `code-style` — where a rule only cloud needs goes                 |
| `testing`            | designing, writing, or reviewing tests                                             |
| `project-testing`    | the same, beside `testing` — where each suite runs and cloud's stand-ins           |
| `docs-writing`       | writing or editing any committed prose: `docs/`, READMEs, this file, skills        |

## Repo structure

cloud is one Bun workspace, plus a Go module and a Nix flake.

```text
infra/             the Pulumi program (TypeScript, Bun runtime)
provider/          the partial Onidel Pulumi provider, a Go module built with pulumi-go-provider's
                   infer package
sdk/onidel/        the provider's generated TypeScript SDK: never edit it by hand, regenerate it
                   with bun run sdk:gen
packages/topology/ the constants that the host, infra, the scripts and the images share, such as
                   ports, CIDRs, tailnet addresses and tags: change one here, never at a reader
packages/preview/  the preview service: one tailnet link per pull request, running in its own imp
packages/files/    the file drop at files.geoff.cloud: token-gated uploads, public reads by an
                   unguessable ID, and expiry
workers/           Cloudflare Workers: the external health check
images/            container images: the agent image, the atc gateway and the files service
nixos/             the host flake
deploy/            the manifests and config of the workloads the cluster runs, such as nixie
scripts/           repo tooling, run through the root package.json scripts
test-support/      the shell suites' assertions and stand-ins
e2e/               journeys that drive real containers from outside
docs/
  architecture/    what is built
  runbooks/        operator and contributor procedures
  reference/       generated reference
```

## Packages

- Pin exact versions, with no `^` or `~` ranges. `bun add` saves exact versions, so the rule covers
  hand-written edits.

## Import boundaries

- The `zgeoff/import-zones` lint rule enforces the import boundaries, and
  [`.oxlintrc.json`](.oxlintrc.json) holds its zones: no relative import into another workspace
  package, and the direction between infra's groups.
- Never add an `oxlint-disable-next-line zgeoff/import-zones` comment to make an import pass. Change
  the import, or change the zones in a PR that reviews the boundary.

## Commands

- lefthook runs the light checks before a commit and a push. Leave the heavier checks to CI, because
  the host may have little memory.
- An agent session runs an operator action, such as a host switch, a workflow dispatch or an apply,
  through its `bun run ops:<verb>` script, never the script or workflow behind it.
  [`docs/runbooks/ops.md`](docs/runbooks/ops.md) lists each verb, what it wraps and its
  preconditions.
- `bun run lint` is plain oxlint. `bun run lint:full` adds the type-aware pass and the type check.
  oxlint runs both through tsrslint (`@maschwenk/tsrslint`), a Rust port of tsgolint, in tsgolint's
  place, because stock tsgolint runs out of memory under 2 GiB. `lint:full` is CI-only: never run it
  locally.
- Run `bun install` in the main checkout before you run `bun run deadcode` in a worktree. knip's
  config loader looks for a `tsconfig.json` from the directory above the worktree, so it reads the
  main checkout's, and without that checkout's `node_modules` knip exits 1 with
  `File '@tsconfig/strictest/tsconfig.json' not found.`

## Public repo and secrets

- This repo is public. Secrets live in the 1Password `cloud` vault. `.env` holds only `op://`
  references, resolved with `op run --env-file=.env -- <command>`.
- Never print a secret, and never log a whole Onidel VM object: the API returns the root password.
- A new service in the cloud stays host-local or on the tailnet by default. A public route, such as
  a tunnel hostname or a public DNS record, needs a stated reason in its PR.

## Host safety

- Never write to `/dev/vdb` on the host directly. It holds the ZFS pool `tank`, which holds imp's
  data. ZFS commands on `tank`, such as `zpool trim tank`, are fine.
- The host's firewall is NixOS's table `inet nixos-fw`, plus `inet cloud_host` for the atc daemon's
  port and the Connect relay. imp's module adds `inet imp-forward`, and k3s and netavark (Podman)
  add their own tables. imp's `inet imp_egress` lives inside the imp-host container. Never
  `flush ruleset`, and keep `networking.nftables.flushRuleset` off.
- Tailscale SSH logs each session's full remote command line in `tailscaled.service`'s journal, and
  Alloy ships the host journal to Loki. So never put a secret in the command line of an SSH session
  to the host, including the `kubectl` arguments and inline scripts it runs. Send the secret on
  SSH's stdin, as `scripts/install-atc-gateway-credentials.ts` does, or read it from a root-only
  file on the host.
- impd owns the DNS records `imps.geoff.cloud`, `*.imps.geoff.cloud` and
  `_acme-challenge.imps.geoff.cloud`. Pulumi never declares them.

## Host switches

- Switch the host with `bash scripts/switch-geoffcloud.sh` from a clean checkout of `main`. It
  builds a `git archive` snapshot of the commit with `nix build --no-link` in a `nixos/nix`
  container, and only after the build exits 0 copies that exact store path to the host and activates
  it. `--build-only` stops after the build.
- Never use `nixos-rebuild build`, because the repo mounts read-only. Never switch by hand after a
  failed build, and never re-evaluate the flake to switch.
- The script refuses an atc daemon pin of another atc major than the running atc gateway's image, so
  roll the gateway out first. It refuses an impd major that the running nixie does not accept, so
  deploy a nixie that accepts it first. It refuses an impd that stores a secret kind the atc daemon
  pin does not accept, so pin an atc that accepts the kind first. It fails the switch when nixie's
  `/health/ready` does not report every part ready afterwards, when an impd image record's build
  folder is gone, or when the host reserved less of its hugetlb pool than it configures.
- The script holds a switch whose activation would stop or restart k3s, because nixie can stay down
  for minutes after it. Pass `--allow-k3s-restart` only in a planned k3s window that the owner
  approved.
- The NixOS checks gate the switch, not the merge: the script refuses a commit that no green
  `NixOS checks` run on `main` covers. Dispatch one with
  `gh workflow run nixos-checks.yml --ref main` when the nightly run has not covered the commit, and
  never switch around the gate.
- Before a switch that changes imp, copy impd's database with
  `bash scripts/copy-impd-db.sh <label>`. It takes a `VACUUM INTO` copy inside imp-host while impd
  runs, and records its integrity check, schema migration and imp version in `COPY-INFO`. Never tar
  the live `imp.sqlite*` files: impd runs in WAL mode, so such a copy can tear.
- A restore of impd's database is one-way, because migrations run forward only. It needs the owner's
  approval and follows `docs/runbooks/restore-geoff-cloud.md`. The host's `/var/lib/imp` is empty:
  `tank/imp` has a legacy mountpoint inside imp-host.

## Pulumi applies

- Preview every live change first. Pulumi's `Acl` replaces the whole Tailscale policy file, so the
  owner reviews the diff before an apply that changes it.
- The `Deploy prod` workflow applies each merged change to a Pulumi input once CI passes on `main`,
  bracketed by drift checks. `docs/runbooks/prod-apply.md` covers its runs. Its guard holds a run
  for any of these:
  - any operation other than a create, an update or a refresh, such as a delete or a replace
  - a change to the tailnet policy, the VM, the cloud firewall, a tunnel's routes, a DNS record or
    the gateway's Access policy
  - a failed drift check, for a manual dispatch
- Never run `bun run up` while a `Deploy prod` run is in progress.
- An apply by hand follows the same bracket, in order: `bun run drift` from a clean checkout of the
  `deployed/prod` tag, `bun run preview -- --refresh` from a clean `main` that shows only the
  reviewed changes, `bun run up`, `bun run drift` again, then move the tag. Record both drift
  results.

## Choices that need the owner

The owner runs this project through a coordinating agent that reaches each session. Its word is the
owner's sign-off.

- Escalate anything you doubt through the coordinating agent, which brings the owner in.
- Before an action that costs money, deletes data or cannot be undone, state its exact effect to the
  coordinating agent. Act only on its approval of that statement, not of a summary.
- A permission-check block needs the owner in person. Tell the coordinating agent, so it can bring
  the owner in.
