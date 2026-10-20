---
name: project-code-style
description:
  cloud's own code-style rules on top of the shared code-style skill. cloud adds no rule of its own,
  so the shared skill and its role table of function verbs hold every rule. Load it beside the
  code-style skill before writing, reviewing, or renaming any TypeScript in cloud.
---

# cloud code style

The shared `code-style` skill holds the rules, and its role table holds every function verb that
makes a promise. cloud adds no rule to them. A verb that cloud uses outside the role table, such as
`decide` or `install`, is a free verb under the shared skill's rules: it makes no promise, so a
reader opens the function to learn what it does.

A rule that only cloud needs goes in this skill. Such a rule adds to the shared skill and never
relaxes a rule there.
