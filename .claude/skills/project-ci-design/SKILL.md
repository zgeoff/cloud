---
name: project-ci-design
description:
  'The CI facts of the cloud repo, the ci-design rules it replaces, and how to add a job behind its
  one required check. Load it beside ci-design before you add, change or review a workflow or a job
  in cloud.'
metadata:
  kind: rule-set
---

# cloud CI design

## Facts

| Fact            | Where                                                                              |
| --------------- | ---------------------------------------------------------------------------------- |
| Test budget     | 1 min                                                                              |
| Required checks | `gh api repos/zgeoff/cloud/rules/branches/main`, the `required_status_checks` rule |

## Departures

- Write each check as a job in cloud's own [`ci.yml`](../../../.github/workflows/ci.yml). The Jobs
  section of [ci-design](../ci-design/SKILL.md) asks for a call to `bun-checks.yml` instead.
  `bun-checks.yml` has no input to set up Go, the Pulumi CLI or the backup and gateway images that
  the fixture suites run, and it can't skip a check whose files a change leaves alone.
- Skip a job through its gate in [`gates.yml`](../../../.github/gates.yml), which the `decide` job
  reads. The Path filters section of [ci-design](../ci-design/SKILL.md) asks for a `changes` job
  that calls `paths-changed.yml` instead. One `decide` job decides every gate in one run. On a push
  to main, it compares the push with main's last green commit, so it still runs the checks that a
  cancelled run skipped.

## The required check

The `main` ruleset requires one check: the `checks` job in
[`ci.yml`](../../../.github/workflows/ci.yml). It needs every other job, always runs, and passes only
when each job passed or its gate skipped it.

While cloud is public, each check runs as its own job. When cloud is private, GitHub bills each job
at least a minute, so the other jobs skip and `checks` runs every check as a step. To add a gated
check:

1. Add the gate to [`gates.yml`](../../../.github/gates.yml).
2. Name the gate in both calls of `ci:decide-ci-gates`
   ([`decide-ci-gates.sh`](../../../scripts/decide-ci-gates.sh)): the one in the `decide` job and
   the one in the decide step of `checks`. Add it to the `outputs` of the `decide` job.
3. Add the job with `needs: decide`, and copy the `if:` of the `test-alert-rules` job with your
   gate in place of `alert-rules`.
4. Add the job to the `needs` of `checks`.
5. Copy the job's steps into `checks`, each with an `if:` on `github.event.repository.private` and
   `steps.decide.outputs.<gate> != 'false'`. Reuse the setup steps in `checks`.

For a check with no gate, skip steps 1 and 2, and leave the gate out of each `if:`.

Never make the `NixOS checks` workflow a required check. It blocks only the deploy to the host.
