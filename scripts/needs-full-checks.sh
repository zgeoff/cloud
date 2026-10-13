#!/usr/bin/env bash
# Decides whether a change needs CI's full checks, or only the fast ones: the full checks add the
# four linters that run in the pinned Nix image (shell, Nix, Python and Actions) and the shell
# suites (test:scripts), which take most of the CI job's time. It prints "false" when every file
# changed between <base> and <head> is Markdown (*.md), which none of those checks reads, and
# "true" otherwise; the CI job skips those checks only on "false". A rename counts both its old
# and new path, so a script renamed to Markdown still needs the checks.
#
# A base of all zeros, as a push that creates a branch reports, has nothing to compare with, so
# it prints "true", and so does a base that is not an ancestor of <head>, such as main before a
# push that rewrote it, and a change with no file at all. An empty argument is a usage error, and
# a base or head git cannot resolve fails the run with git's error, so the job fails rather than
# skipping the checks. Paths are read NUL-separated, so a name git would quote still matches.
#
#   bash scripts/needs-full-checks.sh <base> <head>
set -euo pipefail

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: needs-full-checks.sh <base> <head>" >&2
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

if [ ! -s "$changed" ]; then
  echo true
  exit 0
fi

while IFS= read -r -d '' path; do
  case "$path" in
    *.md) ;;
    *)
      echo true
      exit 0
      ;;
  esac
done < "$changed"
echo false
