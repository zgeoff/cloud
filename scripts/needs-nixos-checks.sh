#!/usr/bin/env bash
# Decides whether a change needs the NixOS checks, which boot VMs and take minutes. It prints
# "true" when any file changed between <base> and <head> is an input of those checks, and "false"
# otherwise; scripts/find-nixos-check-run.sh uses it to decide whether a green run of the checks
# still covers a later commit. The inputs are the flake (nixos/), the test helpers and scripts the
# checks read (scripts/test-lib/, restore-impd-db.sh and copy-impd-db-host.sh), the scripts that
# run them and pin their image (run-nixos-checks.sh and nix-image.sh), the scripts that decide when they
# run (this script and find-nixos-check-run.sh), .bun-version and the workflow itself. A rename
# counts both its old and new path. The root package.json is no input, although its test:nixos
# script runs the checks: it changes with every dependency bump, and a bump would otherwise
# re-run the VM rehearsals. An edit to test:nixos runs at the next change to an input, or on a
# dispatch.
#
# A base of all zeros, as a push that creates a branch reports, has nothing to compare with, so
# it prints "true", and so does a base that is not an ancestor of <head>, such as main before a
# push that rewrote it. An empty argument is a usage error, and a base or head git cannot resolve
# fails the run with git's error, so the workflow fails rather than skipping the checks. Paths are
# read NUL-separated, so a name git would quote still matches.
#
#   bash scripts/needs-nixos-checks.sh <base> <head>
set -euo pipefail

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: needs-nixos-checks.sh <base> <head>" >&2
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
    nixos/* | scripts/test-lib/* | scripts/restore-impd-db.sh | scripts/copy-impd-db-host.sh | \
      scripts/run-nixos-checks.sh | scripts/nix-image.sh | scripts/needs-nixos-checks.sh | \
      scripts/find-nixos-check-run.sh | .bun-version | .github/workflows/nixos-checks.yml)
      echo true
      exit 0
      ;;
  esac
done < "$changed"
echo false
