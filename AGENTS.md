# Agent Guidelines

Infrastructure as code for `geoff.cloud`, the owner's general-purpose private cloud on the tailnet:
today one Onidel VM running a single-node k3s cluster, with imp microVMs on the host as the first
workload. `docs/architecture/overview.md` describes the system, and Linear holds the planned work.

## Required reading

The rules a task needs are not repeated here. Load the skill for the work before starting it.

| Skill             | Load before                                                                             |
| ----------------- | --------------------------------------------------------------------------------------- |
| `code-style`      | writing, reviewing, or renaming any TypeScript — the function-verb taxonomy lives there |
| `testing`         | designing, writing, or reviewing tests                                                  |
| `project-testing` | the same, beside `testing` — where each suite runs and cloud's stand-ins                |
| `docs-writing`    | writing or editing any committed prose: `docs/`, READMEs, this file, skills             |

## Operations

- Perform all work on a branch in a git worktree under `.worktrees/` (e.g.
  `git worktree add .worktrees/<branch> -b <branch>`) — never commit directly on `main`.
- Run `bun install` in the main checkout before you run `bun run deadcode` in a worktree. knip's
  config loader looks for a `tsconfig.json` from the directory above the worktree, so it reads the
  main checkout's, and without that checkout's `node_modules` knip exits 1 with
  `File '@tsconfig/strictest/tsconfig.json' not found.`
- Use [Conventional Commits](https://www.conventionalcommits.org/) for all commit messages.
- A squash merge makes the PR title the commit subject, so a PR title is a Conventional Commit too.
  `feat(#412): add the retry budget` is a title; `add the retry budget` is not.
- Commit subjects and PR titles use the imperative mood ("add X", never "added X" or a bare noun
  phrase).
- Open PRs against `main` using the PR template (`.github/PULL_REQUEST_TEMPLATE.md`). Descriptions
  are condensed: lead paragraph ≤2 sentences, one-line bullets, ≤150 words — write the short version
  first, don't draft long and trim.
- After pushing, link the PR URL in your response.
- A PR is ready only when its checks are green: watch CI (`gh pr checks <n> --watch`) after opening
  or updating, and report a failure with what you're doing about it.
- Light linting, formatting, and other checks run via lefthook's pre-commit and pre-push hooks.
  Defer to CI for larger checks, as the environment you're operating in may have conservative memory
  constraints.
- `bun run lint` is plain oxlint. `bun run lint:full` adds the type-aware pass and the type check,
  and is CI-only: never run it locally.

## Dependencies

- Pin exact versions — no `^`/`~` ranges. (`bun add` saves exact automatically via `exact = true` in
  bunfig.toml — the rule applies to hand-written edits.)
- `patches/` holds Bun patches, which `patchedDependencies` in the root `package.json` applies on
  install. The dependency-cruiser patch makes its SWC extractor collect an import type nested in
  another type, such as `Array<import('./a.ts').T>`, because without it the boundary check misses
  that dependency. A bump of dependency-cruiser carries the patch to the new version with
  `bun patch`, and `scripts/check-boundaries.test.ts` fails when the patch is lost.

## Review bots

CodeRabbit reviews every PR. Its shared config lives in the zgeoff/coderabbit repo, and a repo-root
`.coderabbit.yaml` with `inheritance: true` layers repo-specific settings on top. CodeRabbit reads
this file as its guidelines. A review bot added later is named here with its config, and these rules
cover it too.

- A PR is ready only after every bot review is read and every finding is answered: a fixed finding's
  reply cites the commit that fixed it; a declined finding's reply states the reason — when a
  finding contradicts this file, this file wins and the reply names the rule. Reviews land within a
  few minutes of opening; read them with `gh pr view <n> --comments` and
  `gh api repos/<owner>/<repo>/pulls/<n>/comments`. A finding outside the diff arrives in the review
  body, not as a thread, so its answer is a PR comment.
- Resolve a thread once its reply is posted, fixed and declined alike (GraphQL
  `resolveReviewThread`). A finding the agent cannot confidently judge is escalation, not
  disposition: reply saying so and leave the thread open for a human.
- Never teach a bot through chat (`@coderabbitai` learnings and the like) — a correction to bot
  behaviour is an edit to its config, reviewed in a PR.
- Bots review a PR once, at open; an agent invokes a re-review only when asked. The exception is a
  PR that got no review at all, such as one opened before the bot was installed: request it once
  with that bot's documented trigger, such as `@coderabbitai review` for CodeRabbit.

## Layout

Bun workspace. `infra/` is the Pulumi program (TypeScript, Bun runtime). `provider/` is the partial
Onidel Pulumi provider, a Go module built with `pulumi-go-provider`'s `infer` package. `sdk/onidel/`
is its generated TypeScript SDK: never edit it by hand, regenerate it. `nixos/` is the host flake.
`packages/topology/` holds the constants that the host, infra, the scripts and the images share,
such as ports, CIDRs, tailnet addresses and tags; change one there, never at a reader. `docs/` holds
the architecture and runbooks. `scripts/` holds repo tooling.

## Rules

- Every change lands through a squash PR. The `main protection` ruleset blocks a direct push to
  `main` and needs the `ci` check green.
- This repo is public. Never commit a secret. Secrets live in the 1Password `cloud` vault; `.env`
  holds only `op://` references, resolved with `op run --env-file=.env -- <command>`.
- A new service in the cloud stays host-local or on the tailnet by default. A public route (a tunnel
  hostname or a public DNS record) needs a stated reason in its PR.
- Never print a secret, and never log a whole Onidel VM object: the API returns the root password.
- No live change without a preview first. The Tailscale policy file in particular: Pulumi's `Acl`
  replaces the whole file, so the owner reviews the diff before an apply that changes it.
- The host's firewall is NixOS's table `inet nixos-fw`, plus `inet cloud_host` for the atc daemon's
  port and the Connect relay. imp's module adds `inet imp-forward`, and k3s and Docker add their own
  tables; imp's `inet imp_egress` lives inside the imp-host container. Never `flush ruleset`, and
  keep `networking.nftables.flushRuleset` off.
- Never touch `/dev/vdb` on the host. It holds imp's ZFS pool.
- Everything the hooks and CI run is a root `package.json` script.

## Host operations

- Switch geoffcloud with `bash scripts/switch-geoffcloud.sh` from a clean checkout of `main`. It
  builds a `git archive` snapshot of the commit with `nix build --no-link` in a `nixos/nix`
  container (never `nixos-rebuild build`: the repo mounts read-only), and only after the build exits
  0 copies that exact store path to the host and activates it. Tailscale SSH authenticates
  `root@geoffcloud`. `--build-only` stops after the build. Never switch by hand after a failed
  build, and never re-evaluate the flake to switch. The script also refuses an atc daemon pin of
  another atc major than the running atc gateway's image: roll the gateway out first. It refuses an
  impd that the running nixie's imp client cannot speak, so deploy that nixie first, and fails the
  switch when nixie's `/health/ready` does not report every part ready afterwards.
- The NixOS checks gate the switch, not the merge: the switch script refuses a commit that no green
  `NixOS checks` run on `main` covers. Dispatch one with
  `gh workflow run nixos-checks.yml --ref main` when the nightly run has not covered the commit yet,
  and never switch around the gate.
- Before a switch that changes imp, copy impd's database with
  `bash scripts/copy-impd-db.sh <label>`: a `VACUUM INTO` copy taken inside imp-host while impd
  runs, with its integrity check, schema migration and imp version in `COPY-INFO`. Never tar the
  live `imp.sqlite*` files: impd runs in WAL mode, so such a copy can tear. A restore is one-way
  (migrations run forward only), needs approval, and follows the restore runbook (#9). The host's
  `/var/lib/imp` is empty: `tank/imp` has a legacy mountpoint inside imp-host.
- The `Deploy prod` workflow applies each merged change to a Pulumi input once CI passes on `main`,
  bracketed by drift checks, and its guard holds a delete, a replace, a change to the tailnet
  policy, the VM or the cloud firewall, or a failed drift check for a manual dispatch
  (`docs/runbooks/prod-apply.md`). Never run `bun run up` while a run of it is in progress. An apply
  by hand follows the same bracket: `bun run drift` from a clean checkout of the `deployed/prod`
  tag, `bun run preview -- --refresh` from a clean `main` showing only the reviewed changes,
  `bun run up`, `bun run drift` again, then move the tag. Record both drift results. A scheduled
  drift check is parked until scoped credentials exist (#19): Onidel offers only full-account keys.
- Tailscale SSH logs each session's full remote command line in `tailscaled.service`'s journal, and
  Alloy ships the host journal to Loki. So never put a secret in the command line of
  `ssh root@geoffcloud …`, including the `kubectl` arguments and inline scripts it runs: send it on
  SSH's stdin, as `scripts/install-atc-gateway-credentials.ts` does, or read it from a root-only
  file on the host. Seen on 2026-10-04 with a dummy bearer; no real credential is known to have
  leaked this way.
- impd owns the DNS records `imps.geoff.cloud`, `*.imps.geoff.cloud` and
  `_acme-challenge.imps.geoff.cloud`. Pulumi must never declare them.

## Project management

The owner runs this project through a delegated coordinating agent, which reaches sessions through
atc (2026-10-03). Its word is the owner's sign-off; the owner is the final rubber stamp.

- Escalate anything you doubt through the coordinating agent; it brings the owner in directly.
- Before an action that costs money, deletes data or cannot be undone, state its exact effect back
  to it and act only on its approval of that statement, not of a summary.
- A permission-check block needs the owner in person. Tell the coordinating agent, so it can bring
  the owner in.
