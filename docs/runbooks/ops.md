# Operator verbs

Each `bun run ops:<verb>` script is the stable name of one action that an operator or an agent
session takes on cloud: switch the host, dispatch a workflow, preview or apply the prod stack,
switch the agent image, run a root step on the host, or clear a stale prod stack lock. A caller
names the verb and never the script, workflow file or address behind it, so a change to those
changes [`scripts/ops.sh`](../../scripts/ops.sh) and leaves the callers alone.

A verb runs the command it wraps unchanged and passes its exit code through. Every check the wrapped
script makes still runs, and this page lists the preconditions that no script checks. Two verbs add
one check of their own: `up` and `cancel-prod-lock` refuse with exit 1, and name each run, while a
`Deploy prod` run is queued or in progress, since either would fight that run for the prod stack.
The check asks GitHub for each status that a run holds before it completes: in progress, queued,
waiting, pending and requested. A usage error exits 2.

**CAUTION:** Every verb but a dry run acts on the live estate or on GitHub. Read the preconditions
of a verb before you run it.

To see what a verb would run, pass `--dry-run` as its first argument. It prints the check the verb
makes first, if any, and the command with its working directory, then exits 0 and runs neither:

```bash
bun run ops:cancel-prod-lock -- --dry-run --yes
```

```text
check: no Deploy prod run of zgeoff/cloud is queued or in progress
run in <checkout>/infra: op run --env-file=../.env -- pulumi cancel --stack prod --yes
```

## `bun run ops:switch-host`

Switches geoffcloud to the NixOS system of the checked-out `main`.

```bash
bun run ops:switch-host                               # build, then switch
bun run ops:switch-host -- --build-only               # build and print the system path
bun run ops:switch-host -- --allow-k3s-restart        # switch in a planned k3s window
```

- Wraps `bash scripts/switch-geoffcloud.sh`, which reaches the host in `GEOFFCLOUD_HOST`, or
  `root@geoffcloud`.
- The script checks a clean `main` that matches `origin/main`, a green `NixOS checks` run that
  covers the commit, the atc daemon and gateway majors, nixie's imp client against impd, a k3s
  restart, and nixie's readiness after the switch. [Switch the host](./workflows.md#switch-the-host)
  explains each refusal.
- Before a switch that changes imp, copy impd's database with
  `bash scripts/copy-impd-db.sh <label>`.
- Pass `--allow-k3s-restart` only in a planned k3s window that the owner approved.

## `bun run ops:deploy-prod`

Dispatches the `Deploy prod` workflow on `main` for a held run.

```bash
bun run ops:deploy-prod -- <full commit of main's tip>
```

- Wraps `gh workflow run deploy-prod.yml -R zgeoff/cloud --ref main -f revision=<commit>`.
- The verb refuses a commit that is not 40 lowercase hex characters. The workflow refuses a revision
  that is not `main`'s tip or that has no green CI run.
- Read the held plan in full first. [The prod apply job](./prod-apply.md) covers a held run.

## `bun run ops:nixos-checks`

Dispatches the `NixOS checks` workflow, on `main` by default.

```bash
bun run ops:nixos-checks                    # on main, before a host switch
bun run ops:nixos-checks -- <branch>        # on a pushed branch
```

- Wraps `gh workflow run nixos-checks.yml -R zgeoff/cloud --ref <branch>`.
- A host switch reads only a green run on `main`. A run on a branch checks the change and gates
  nothing.

## `bun run ops:preview`

Previews the prod stack.

```bash
bun run ops:preview
bun run ops:preview -- --refresh
```

- Wraps `bun run preview` from the checkout's root, with the flags you pass after `--`.
- It needs `op` signed in to the `cloud` vault, because `.env` holds `op://` references.

## `bun run ops:up`

Applies the checked-out commit to the prod stack.

```bash
bun run ops:up -- --yes
```

- Wraps `bun run up` from the checkout's root, with the flags you pass after `--`.
- The verb refuses while a `Deploy prod` run is queued or in progress.
- Follow the bracket in [AGENTS.md](../../AGENTS.md#pulumi-applies): a drift check from the
  `deployed/prod` tag, a preview from a clean `main` that shows only the reviewed changes, the
  apply, a second drift check, then the tag move.

## `bun run ops:switch-agent-image`

Points the atc daemon's `cloud` target at an agent image in imp's image store.

```bash
bun run ops:switch-agent-image -- agent-<short sha>
bun run ops:switch-agent-image -- agent-<short sha> <atc config file>
```

- Wraps `bun scripts/switch-agent-image.ts`. Run it on the machine that runs the atc daemon.
- The script refuses an image that `imp image ls` does not list, and backs up the config before it
  writes it.
- Build and check the image first, and restart the daemon after, as
  [Switch the `cloud` target](./agent-image.md#switch-the-cloud-target) describes.

## `bun run ops:host`

Runs one command as root on geoffcloud.

```bash
bun run ops:host -- 'systemctl is-active k3s'
printf '%s\n' "$value" | bun run ops:host -- 'install -m 600 /dev/stdin /root/<file>'
```

- Wraps `ssh -o BatchMode=yes root@geoffcloud '<command>'`, or the host in `GEOFFCLOUD_HOST`. Your
  stdin reaches the command.
- The verb takes exactly one argument: the whole remote command, quoted.

**WARNING:** Tailscale SSH logs each session's full command line, and Alloy ships that log to Loki.
Never put a secret in the command. Send the secret on stdin, as the second example does.

## `bun run ops:cancel-prod-lock`

Clears a stale lock on the prod stack's Pulumi state, which an apply or a preview leaves when it
dies before it finishes.

```bash
bun run ops:cancel-prod-lock -- --yes
```

- Wraps `pulumi cancel --stack prod` under `op run --env-file=../.env`, from `infra/`, with the
  flags you pass after `--`.
- The verb refuses while a `Deploy prod` run is queued or in progress.
- The scheduled drift check on the host also takes the Pulumi lock. Check that the host's
  `drift-check` service is not active first, with
  `bun run ops:host -- 'systemctl is-active drift-check'`.
  [The scheduled drift check](./drift-check.md) describes the service.

**CAUTION:** `pulumi cancel` ends the update that holds the lock, and a live update stops half
applied. Cancel only a lock whose holder you know has died.
