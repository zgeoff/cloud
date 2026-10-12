#!/usr/bin/env bash
# Decides whether a change needs the provider's Go checks, which compile with -race and take
# minutes from a cold cache. It prints "true" when any file changed between <base> and <head> is
# an input of those checks, and "false" otherwise; the CI job runs the checks only on "true", and
# reports a result on every pull request either way. The inputs are the Go module and its check
# script (provider/) and the CI workflow, which sets Go up. The root package.json only calls
# provider/check.sh, so it is not an input. A rename counts both its old and new path.
#
# A base of all zeros, as a push that creates a branch reports, has nothing to compare with, so
# it prints "true", and so does a base that is not an ancestor of <head>, such as main before a
# push that rewrote it. An empty argument is a usage error, and a base or head git cannot resolve
# fails the run with git's error, so the job fails rather than skipping the checks. Paths are
# read NUL-separated, so a name git would quote still matches.
#
#   bash scripts/needs-provider-check.sh <base> <head>
set -euo pipefail

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: needs-provider-check.sh <base> <head>" >&2
  exit 2
fi
base="$1"
head="$2"

if [[ "$base" =~ ^0+$ ]]; then
  echo true
  exit 0
fi

changed="$(mktemp)"
trap 'rm -f "$changed"' EXIT
git diff -z --no-renames --name-only "$base...$head" > "$changed"

if ! git merge-base --is-ancestor "$base" "$head"; then
  echo true
  exit 0
fi

while IFS= read -r -d '' path; do
  case "$path" in
    provider/* | .github/workflows/ci.yml)
      echo true
      exit 0
      ;;
  esac
done < "$changed"
echo false
