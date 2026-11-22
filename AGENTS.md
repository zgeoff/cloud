# Agent Guidelines

Infrastructure as code for `geoff.cloud`, the owner's general-purpose private cloud on the tailnet:
one Onidel VM running a single-node k3s cluster, with imp microVMs on the host as the first
workload. `docs/architecture/overview.md` describes the system, and Linear holds the planned work.

## Required reading

Each skill below holds the rules for one kind of work, and this file doesn't repeat them. Load the
skill for the work before starting it. The rest of this file holds the rules that cover the whole
repo.

| Skill                | Load before                                                                                |
| -------------------- | ------------------------------------------------------------------------------------------ |
| `code-style`         | writing, reviewing, or renaming any TypeScript — the shared function-verb taxonomy         |
| `project-code-style` | the same as `code-style`: cloud adds and replaces no code-style rule                       |
| `testing`            | designing, writing, or reviewing tests                                                     |
| `project-testing`    | the same as `testing`: cloud's lanes, harnesses and stand-ins, and the rules it replaces   |
| `ci-design`          | adding, changing, or reviewing a workflow or a job                                         |
| `project-ci-design`  | the same as `ci-design`: cloud's test budget and required check, and the rules it replaces |
| `docs-writing`       | writing or editing any committed prose: `docs/`, READMEs, this file, skills                |
| `skill-writing`      | writing or editing a skill                                                                 |
| `cold-read`          | checking a skill you wrote or changed, before its PR                                       |
| `deslop`             | editing the prose of a skill you wrote or changed, before its PR                           |

When you write or edit a skill:

1. Load the `skill-writing`, `cold-read` and `deslop` skills from `.agents/skills/`. repo-sync
   delivers them there at the `zgeoff/skills` commit that `zgeoff/tools` pins, so install none of
   them yourself.
2. Do every step in the "Check it" section of `.agents/skills/skill-writing/SKILL.md`. In its last
   step, you fill in the `## Checks` section of the PR template.

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
  src/test-utils/  the test helpers; shell/ holds the shell suites' assertions and stand-ins
  e2e/             journeys that drive real containers from outside
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
- Run each operator action that has a `bun run ops:<verb>` script through that script, never the
  script or workflow behind it: `ops:switch-host` for a host switch, `ops:nixos-checks` for a
  `NixOS checks` dispatch, and `ops:preview` and `ops:up` for a preview and an apply of the prod
  stack. [`docs/runbooks/ops.md`](docs/runbooks/ops.md) lists each verb, what it wraps and its
  preconditions. Run a command that has no verb, such as `bun run drift`, as this file gives it.
- `bun run lint` is plain oxlint. `bun run lint:full` adds the type-aware pass and the type check.
  oxlint runs both through `tsrs-lint`, which the `tsrs` package ships and oxlint finds on its own,
  in tsgolint's place, because stock tsgolint runs out of memory under 2 GiB. The script builds the
  SDK first, so the type check reads its declarations and not its generated sources, then sets
  `TSRS_FAST=1`, tsrs's fast mode. `lint:full` is CI-only: never run it locally.

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
  port and the three bridge relays (Connect, pepys ingest and the boxxy worker Service). imp's
  module adds `inet imp-forward`, and k3s and netavark (Podman) add their own tables. imp's
  `inet imp_egress` lives inside the imp-host container. Never `flush ruleset`, and keep
  `networking.nftables.flushRuleset` off.
- Tailscale SSH logs each session's full remote command line in `tailscaled.service`'s journal, and
  Alloy ships the host journal to Loki. So never put a secret in the command line of an SSH session
  to the host, including the `kubectl` arguments and inline scripts it runs. Send the secret on
  SSH's stdin, as `scripts/install-atc-gateway-credentials.ts` does, or read it from a root-only
  file on the host.
- impd owns the DNS records `imps.geoff.cloud`, `*.imps.geoff.cloud` and
  `_acme-challenge.imps.geoff.cloud`. Pulumi never declares them.

## Host switches

- Switch the host with `bun run ops:switch-host` from a clean checkout of `main`. It runs
  `scripts/switch-geoffcloud.sh`, the switch script, which builds a `git archive` snapshot of the
  commit with `nix build --no-link` in a `nixos/nix` container. Only after the build exits 0 does it
  copy that exact store path to the host and activate it. `--build-only` stops after the build.
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
- The NixOS checks gate the switch, not the merge: the script refuses a commit that neither a green
  `NixOS checks` run on `main` covers, nor the green `nixos` check of the merged pull request that
  produced it when no NixOS input differs between its head and the commit. Dispatch a run with
  `bun run ops:nixos-checks` when neither covers the commit, and never switch around the gate.
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
  - a delete, a replace, or any other operation that isn't a create, an update or a refresh, apart
    from the one replace the next paragraph describes
  - a change to the tailnet policy, the VM, the cloud firewall, a tunnel's routes, a DNS record or
    the gateway's Access policy
  - a failed drift check, for a manual dispatch

  A merge that changes only `deploy/nixie/secrets.sops.yaml` applies with no manual dispatch. Its
  plan replaces nixie's Secrets, whose names Pulumi generates, because the infra code sets no
  `metadata.name` on them, and the guard passes a replace of such an object when only its data
  changed. The guard holds the same change to an object whose `metadata.name` the code sets, so it
  holds every change to `deploy/nixie/config.yaml`: nixie's backup job keeps a copy of that file in
  `nixie-backup-config`, a ConfigMap with a fixed name. Give such an object
  `deleteBeforeReplace: true`, or its replacement fails on the taken name.
  [The apply job](docs/architecture/infrastructure-as-code.md#the-apply-job) gives the reason.

- Never apply by hand while a `Deploy prod` run is queued or in progress, because both would change
  the prod stack at once. `bun run ops:up` refuses then.
- Apply by hand inside the same bracket, in this order, and record both drift results:
  1. `bun run drift` from a clean checkout of the `deployed/prod` tag.
  2. `bun run ops:preview -- --refresh` from a clean `main`. Expect only the reviewed changes.
  3. `bun run ops:up`.
  4. `bun run drift` again.
  5. Move the `deployed/prod` tag to the applied commit, as
     [`docs/runbooks/workflows.md`](docs/runbooks/workflows.md) shows.

## Choices that need the owner

The owner runs this project through a coordinating agent that reaches each session. Its word is the
owner's sign-off.

- Escalate anything you doubt through the coordinating agent, which brings the owner in.
- Before an action that costs money, deletes data or cannot be undone, state its exact effect to the
  coordinating agent. Act only on its approval of that statement, not of a summary.
- A permission-check block needs the owner in person. Tell the coordinating agent, so it can bring
  the owner in.
