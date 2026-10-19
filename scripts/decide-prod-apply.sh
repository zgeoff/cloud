#!/usr/bin/env bash
# The Deploy prod workflow's decision, from the repo alone and with no secret: which commit to
# apply, and whether it needs an apply at all. It writes apply (true or false) and revision to
# $GITHUB_OUTPUT, for the apply job.
#
# A dispatch (EVENT=workflow_dispatch) applies main's tip only: DISPATCH_REF must be
# refs/heads/main and DISPATCH_REVISION, the commit the person named, must equal DISPATCH_SHA.
# Because a dispatch skips the trigger that waits for CI, it also needs a green CI run of a push
# to main on that commit (find-ci-run.sh), and prints the run's URL. Any other event applies
# RUN_HEAD, the commit the CI run checked. Either way the commit must be on origin/main.
# run-decide-gates.ts decides, from the prod-apply gate of .github/gates.yml, whether a commit after the
# deployed/prod tag changes a Pulumi input; when none does, it says so on stdout and in $GITHUB_STEP_SUMMARY, naming the tag's commit and the revision,
# because a workflow_run run's own head commit is main's tip when the run started, which can be a
# later merge than the commit it decides on. This job runs outside the deploy-prod
# queue, so another apply can move the tag after it reads it: the apply job decides again once it
# holds the queue (decide-queued-prod-apply.sh). A "false" here stays true then, because the tag
# only moves forward along main.
#
# A refused dispatch, a missing green run, a commit off main, a tag git cannot resolve, and a
# failure of either helper fail the run with exit 1 (git's own status for the tag, the helper's
# for a helper), so the job never skips an apply it cannot decide. Missing GitHub variables are
# a usage error (exit 2).
#
#   EVENT=workflow_run RUN_HEAD=<commit> bash scripts/decide-prod-apply.sh
#   EVENT=workflow_dispatch DISPATCH_REF=<ref> DISPATCH_SHA=<commit> DISPATCH_REVISION=<commit> \
#     bash scripts/decide-prod-apply.sh
#
# It also reads GITHUB_OUTPUT and GITHUB_STEP_SUMMARY, and runs in the checkout, with the full
# history and tags.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for name in EVENT GITHUB_OUTPUT GITHUB_STEP_SUMMARY; do
  if [ -z "${!name:-}" ]; then
    echo "decide-prod-apply: set $name" >&2
    exit 2
  fi
done

# a dispatch applies main's tip, only when the person named it and only after CI passed on it,
# since a dispatch skips the trigger that waits for CI; a CI run applies the commit it checked,
# which must be on main
if [ "$EVENT" = workflow_dispatch ]; then
  if [ "${DISPATCH_REF:-}" != refs/heads/main ] || [ "${DISPATCH_REVISION:-}" != "${DISPATCH_SHA:-}" ]; then
    echo "a dispatch applies main's tip only: dispatch on main with revision ${DISPATCH_SHA:-}" >&2
    exit 1
  fi
  ci_run="$(bash "$here/find-ci-run.sh" "$DISPATCH_SHA")"
  if [ -z "$ci_run" ]; then
    echo "no green CI run of a push to main on $DISPATCH_SHA: wait for CI to pass" >&2
    exit 1
  fi
  echo "CI passed on $DISPATCH_SHA: $ci_run"
  revision="$DISPATCH_SHA"
else
  revision="${RUN_HEAD:-}"
fi
git merge-base --is-ancestor "$revision" origin/main || {
  echo "$revision is not on main" >&2
  exit 1
}
deployed="$(git rev-parse --verify 'deployed/prod^{commit}')"
# a revision the tag already holds needs nothing, as for a run that waited behind a newer one; a
# tag off the revision's history needs a person, because only a person can say which revision is
# live
if git merge-base --is-ancestor "$revision" "$deployed"; then
  apply=false
elif ! git merge-base --is-ancestor "$deployed" "$revision"; then
  echo "decide-prod-apply: deployed/prod at $deployed is not an ancestor of $revision; set the tag by hand at the live revision" >&2
  exit 1
else
  decision="$(bun "$here/run-decide-gates.ts" "$deployed" "$revision" prod-apply)"
  apply="${decision#prod-apply=}"
fi
case "$apply" in
  true | false) ;;
  *)
    echo "unexpected decision: $apply" >&2
    exit 1
    ;;
esac
{
  echo "apply=$apply"
  echo "revision=$revision"
} >> "$GITHUB_OUTPUT"
if [ "$apply" = false ]; then
  echo "No commit after deployed/prod at $deployed up to $revision changes a Pulumi input, so nothing applied." |
    tee -a "$GITHUB_STEP_SUMMARY"
fi
