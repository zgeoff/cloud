---
name: project-code-style
description:
  cloud's own function verbs on top of the shared code-style skill — decide, install, open, and
  switch, and how each differs from the shared verbs beside it. Load it beside the code-style skill before
  writing, reviewing, or renaming any TypeScript in cloud.
---

# cloud code style

The shared `code-style` skill holds the rules and the role table of verbs. This skill holds only
what cloud adds to them, and never relaxes a rule there.

## Project verbs

The role table leaves these verbs free, and cloud gives each a fixed meaning. Each sits close to a
shared verb, so each carries the meaning that tells it apart: `decide` is a pure producer, and the
others are effectful. A function that starts with one of them keeps its meaning here.

- `decide`: picks one outcome of a closed set, with its reason, from the facts it is given, as
  opposed to `pick`, which selects among known alternatives and gives no reason, and `plan`, which
  computes an action to perform. [`decide`](../../../scripts/release/decide.ts) is one.
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
