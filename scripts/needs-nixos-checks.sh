#!/usr/bin/env bash
# Decides whether a change needs the NixOS checks, which boot VMs and take minutes. It prints
# "true" when any file changed between <base> and <head> is an input of those checks, and "false"
# otherwise; scripts/find-nixos-check-run.sh uses it to decide whether a green run of the checks
# still covers a later commit. The inputs are the flake (nixos/), which holds the impd database
# tools the restore rehearsals run, the shared constants it reads (packages/topology/), the shell
# test helpers the checks read from test-support/shell (the files
# nixos/checks/test-utils/build-shell-lib-source.nix selects, and no other file there), the
# scripts that run them and pin their image (run-nixos-checks.sh and nix-image.sh), the scripts
# that decide when they run (this script, find-nixos-check-run.sh and decide-nixos-checks.sh),
# the script that opens KVM to them (open-kvm.sh), the scripts that tank-cloud-host-secrets runs in
# its VM (install-imp-dns-token.sh and host/write-atc-gateway-token.sh), .bun-version, the
# workflow itself, the preview service's source (packages/preview/), which the host's package copies, and bun.lock,
# from which that package fetches the service's dependencies, so every dependency bump runs the
# checks. A rename counts both its old and new path. The root package.json is no input, although
# its test:nixos script runs the checks: a change to it alone, such as a script edit, runs at the
# next change to an input, or on a dispatch.
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
    nixos/* | packages/topology/* | packages/preview/* | \
      test-support/shell/run-cases.sh | test-support/shell/test-run-cases.sh | \
      test-support/shell/assert-equals.sh | test-support/shell/test-assert-equals.sh | \
      test-support/shell/assert-not-equals.sh | test-support/shell/test-assert-not-equals.sh | \
      test-support/shell/assert-files-equal.sh | test-support/shell/test-assert-files-equal.sh | \
      test-support/shell/assert-between.sh | test-support/shell/test-assert-between.sh | \
      test-support/shell/assert-missing.sh | test-support/shell/test-assert-missing.sh | \
      test-support/shell/wait-for.sh | \
      scripts/run-nixos-checks.sh | scripts/nix-image.sh | scripts/needs-nixos-checks.sh | \
      scripts/find-nixos-check-run.sh | scripts/decide-nixos-checks.sh | scripts/open-kvm.sh | \
      scripts/install-imp-dns-token.sh | scripts/host/write-atc-gateway-token.sh | \
      .bun-version | bun.lock | .github/workflows/nixos-checks.yml)
      echo true
      exit 0
      ;;
  esac
done < "$changed"
echo false
