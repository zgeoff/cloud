#!/usr/bin/env bash
# Checks that a change is an atc pin and nothing else: from the merge base of <base> and <head>,
# it changes one file, images/agent/Dockerfile, keeps that file's mode, and replaces exactly one
# `ARG ATC_VERSION=<x.y.z>` line and one `ARG ATC_SHA256=<64 hex>` line. It prints one line and
# exits 0 when the change passes, and names the first thing that breaks the rule and exits 1
# otherwise. A base or head git cannot resolve fails the run with git's error.
#
# The agent image workflow runs it on the release bot's pin pull request before it turns on
# auto-merge, so any other change waits for a person.
#
#   bash scripts/check-atc-pin-diff.sh <base> <head>
set -euo pipefail

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: check-atc-pin-diff.sh <base> <head>" >&2
  exit 2
fi
range="$1...$2"
dockerfile=images/agent/Dockerfile

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git diff -z --no-renames --name-only "$range" > "$work/files"
if [ ! -s "$work/files" ]; then
  echo "the diff changes nothing" >&2
  exit 1
fi
while IFS= read -r -d '' path; do
  if [ "$path" != "$dockerfile" ]; then
    echo "the diff changes $path, not only $dockerfile" >&2
    exit 1
  fi
done < "$work/files"

git diff --no-renames --summary "$range" > "$work/summary"
if [ -s "$work/summary" ]; then
  echo "the diff changes a file mode, or creates or removes a file: $(sed 's/^ *//' "$work/summary" | head -1)" >&2
  exit 1
fi

# the changed lines only: -U0 drops context, and the hunk headers start each hunk's lines
git diff --no-renames -U0 "$range" -- "$dockerfile" | awk '/^@@/ { hunk = 1; next } hunk' > "$work/lines"
removed_version=0 added_version=0 removed_sum=0 added_sum=0
while IFS= read -r line; do
  if [[ "$line" =~ ^-ARG\ ATC_VERSION= ]]; then
    removed_version=$((removed_version + 1))
  elif [[ "$line" =~ ^\+ARG\ ATC_VERSION=[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    added_version=$((added_version + 1))
  elif [[ "$line" =~ ^-ARG\ ATC_SHA256= ]]; then
    removed_sum=$((removed_sum + 1))
  elif [[ "$line" =~ ^\+ARG\ ATC_SHA256=[0-9a-f]{64}$ ]]; then
    added_sum=$((added_sum + 1))
  else
    echo "the diff changes a Dockerfile line other than the atc pins: $line" >&2
    exit 1
  fi
done < "$work/lines"

if [ "$removed_version$added_version$removed_sum$added_sum" != 1111 ]; then
  echo "the diff must replace each atc pin once; it removes $removed_version and adds $added_version ATC_VERSION lines, and removes $removed_sum and adds $added_sum ATC_SHA256 lines" >&2
  exit 1
fi
echo "the diff changes only the atc pins in $dockerfile"
