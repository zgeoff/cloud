---
name: project-code-style
description:
  cloud's own function verbs on top of the shared code-style skill — decide, install, open, and
  switch, and how each differs from the shared verbs beside it. Load it beside the code-style skill before
  writing, reviewing, or renaming any TypeScript in cloud.
---

# cloud code style

The shared `code-style` skill holds the rules and the shared verbs. This skill holds only what
cloud adds to them, and never relaxes a rule there.

## Project verbs

cloud gives each of these verbs a job that no shared verb names. Each sits close to a shared verb,
so each says what tells it apart: `decide` is a pure producer, and the others are effectful.

- `decide`: returns a verdict from the facts it is given. A verdict is one outcome of a closed set
  with the data the caller acts on, such as the reason a run holds. A function that returns only
  the chosen alternative makes a choice and starts with `pick`, and one that computes an action to
  perform starts with `plan`.
  [`decide`](../../../scripts/release/decide.ts) is one.
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
