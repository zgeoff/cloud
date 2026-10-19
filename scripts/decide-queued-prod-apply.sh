#!/usr/bin/env bash
# The prod apply job's own decision, made once the job holds the deploy-prod concurrency group, so
# no other apply moves the deployed/prod tag under it. It resolves the tag as it stands now and asks
# decide-gates.ts again whether REVISION, the commit the decide job chose, needs an apply: a
# job that waited behind a newer commit's apply finds its commit already deployed. It writes apply
# (true or false) and deployed, the tag's commit, to $GITHUB_OUTPUT, for the job's later steps;
# when apply is false, it says so on stdout and in $GITHUB_STEP_SUMMARY.
#
# A tag git cannot resolve fails the run with git's status, a tag that has left main with exit 1,
# and a failure of decide-gates.ts with its status, so the job never skips an apply it cannot
# decide. A missing variable is a usage error (exit 2).
#
#   REVISION=<commit> bash scripts/decide-queued-prod-apply.sh
#
# It also reads GITHUB_OUTPUT and GITHUB_STEP_SUMMARY, and runs in the job's checkout, with the
# full history and tags fetched after the job took the group.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for name in REVISION GITHUB_OUTPUT GITHUB_STEP_SUMMARY; do
  if [ -z "${!name:-}" ]; then
    echo "decide-queued-prod-apply: set $name" >&2
    exit 2
  fi
done

deployed="$(git rev-parse --verify 'deployed/prod^{commit}')"
# a revision the tag already holds needs nothing, as for a run that waited behind a newer one; a
# tag off the revision's history needs a person, because only a person can say which revision is
# live
if git merge-base --is-ancestor "$REVISION" "$deployed"; then
  apply=false
elif ! git merge-base --is-ancestor "$deployed" "$REVISION"; then
  echo "decide-queued-prod-apply: deployed/prod at $deployed is not an ancestor of $REVISION; set the tag by hand at the live revision" >&2
  exit 1
else
  decision="$(bun "$here/decide-gates.ts" "$deployed" "$REVISION" prod-apply)"
  apply="${decision#prod-apply=}"
fi
{
  echo "apply=$apply"
  echo "deployed=$deployed"
} >> "$GITHUB_OUTPUT"
if [ "$apply" = false ]; then
  echo "deployed/prod at $deployed already holds every Pulumi input of $REVISION, so nothing applied." |
    tee -a "$GITHUB_STEP_SUMMARY"
fi
