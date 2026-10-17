---
name: project-code-style
description:
  cloud's own function verbs on top of the shared code-style skill — install, open, and switch, and
  how each differs from the shared verbs beside it. Load it beside the code-style skill before
  writing, reviewing, or renaming any TypeScript in cloud.
---

# cloud code style

The shared `code-style` skill holds the rules and the shared verb list. This skill holds only what
cloud adds to them, and never relaxes a rule there.

## Project verbs

cloud adds these verbs to the shared taxonomy. Each sits close to a shared effectful verb, so each
carries the meaning that tells it apart. A new verb goes here and into the `verbs` option of
`zgeoff/function-verb` in [`.oxlintrc.json`](../../../.oxlintrc.json) in the same PR, and
`check-project-verbs.sh` fails when the two lists differ.

- `install`: puts a credential or artifact where its consumer reads it, skipping each part that
  already exists, as opposed to `create`, which brings a new resource into existence, and `write`,
  which persists what it is given.
  [`installATCGLMSecret`](../../../scripts/install-atc-glm-secret.ts) is one.
- `open`: opens a pull request or issue on a forge, or brings the open one up to date, as opposed
  to `create`, which brings a new resource into existence, and `send`, which transmits a payload
  with no resource behind it.
- `switch`: points a consumer at another artifact and keeps a backup of what it pointed at, as
  opposed to `set` and `update`, which change state in place and keep no backup.
  [`switchAgentImage`](../../../scripts/switch-agent-image.ts) is one.
