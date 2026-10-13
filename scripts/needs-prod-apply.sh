#!/usr/bin/env bash
# Decides whether a commit on main needs the prod apply. It prints "true" when any file changed
# between <deployed> (the deployed/prod tag, the last applied revision) and <head> is an input of
# the Pulumi program: infra/, deploy/, provider/ or sdk/. It prints "false" for a change to
# nothing else, such as docs, and for a head that is already deployed: <head> equal to
# <deployed>, or its ancestor, as for a run that waited behind a newer one. A rename counts both
# its old and new path.
#
# A head that neither descends from <deployed> nor is its ancestor fails with exit 1, because
# the tag has left main and only a person can say which revision is live. An empty argument is a
# usage error (exit 2), and a revision git cannot resolve, such as a tag never set, fails the run
# with git's error, so the job fails rather than skipping the apply. Paths are read
# NUL-separated, so a name git would quote still matches.
#
#   bash scripts/needs-prod-apply.sh <deployed> <head>
set -euo pipefail

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: needs-prod-apply.sh <deployed> <head>" >&2
  exit 2
fi
deployed="$(git rev-parse --verify --quiet "$1^{commit}" || git rev-parse --verify "$1")"
head="$(git rev-parse --verify --quiet "$2^{commit}" || git rev-parse --verify "$2")"

if git merge-base --is-ancestor "$head" "$deployed"; then
  echo false
  exit 0
fi

if ! git merge-base --is-ancestor "$deployed" "$head"; then
  echo "needs-prod-apply: $1 is not an ancestor of $2; set the tag by hand at the live revision" >&2
  exit 1
fi

changed="$(mktemp)"
trap 'rm -f "$changed"' EXIT
git diff -z --no-renames --name-only "$deployed" "$head" > "$changed"

while IFS= read -r -d '' path; do
  case "$path" in
    infra/* | deploy/* | provider/* | sdk/*)
      echo true
      exit 0
      ;;
  esac
done < "$changed"
echo false
