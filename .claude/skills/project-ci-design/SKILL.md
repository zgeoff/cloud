---
name: project-ci-design
description:
  'The CI facts of the cloud repo, the ci-design rules it replaces, and how its one required check
  works. Load it beside ci-design before you add, change or review a workflow or a job in cloud.'
metadata:
  kind: rule-set
---

# cloud CI design

## Facts

| Fact            | Where                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------- |
| Test budget     | 1 min                                                                                     |
| Required checks | `gh api repos/zgeoff/cloud/rules/branches/main`, the `required_status_checks` rule |

## Departures

- Write the checks as jobs of cloud's own [`ci.yml`](../../../.github/workflows/ci.yml), never as a
  call to `bun-checks.yml`, which the Jobs section of [ci-design](../ci-design/SKILL.md) asks for.
  `bun-checks.yml` has no input to set up Go, the Pulumi CLI or the Docker images, and gates no
  check on the files a change touches.
- Gate a job on a gate in [`gates.yml`](../../../.github/gates.yml), read by the `decide` job, never
  on a `changes` job that calls `paths-changed.yml`, which the path filters section of
  [ci-design](../ci-design/SKILL.md) asks for. One decision answers every gate, and a push to main
  compares main's last green commit, so it checks a cancelled run's changes too.

## The required check

`checks` in [`ci.yml`](../../../.github/workflows/ci.yml) is the one check the `main` ruleset
requires. It needs every other job, always runs, and passes only when each job passed or its gate
skipped it.

- When you add a job, add it to the `needs` of `checks`, and add its steps to `checks` too, under the
  `github.event.repository.private` condition that the other steps there use. Once cloud is private,
  the other jobs skip and `checks` runs every check as a step.
- When you gate a new check, add its gate to [`gates.yml`](../../../.github/gates.yml), name it in
  the `ci:decide-ci-gates` call of both the `decide` job and the `checks` job's decide step, and add
  it to the `decide` job's outputs.
- Never make the `NixOS checks` workflow a required check. It gates only the host switch.
