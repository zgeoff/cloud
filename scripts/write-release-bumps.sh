#!/usr/bin/env bash
# Hands the release check's bump job its work: it runs find-release-bumps.sh in the checkout it
# runs from and writes its lines, one bump per line, as the multiline output `bumps` to
# GITHUB_OUTPUT. It lists them on stdout and in GITHUB_STEP_SUMMARY, or says there that every pin
# holds its newest release and writes no output, which skips the bump job. A failure of the search
# fails it with that error and writes nothing. The release check workflow's check job runs it from
# the checkout's root, with gh signed in:
#
#   bash scripts/write-release-bumps.sh
set -euo pipefail

: "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bumps="$(bash "$here/find-release-bumps.sh")"
if [ -z "$bumps" ]; then
  echo "Every pin holds its newest release." | tee -a "$GITHUB_STEP_SUMMARY"
  exit 0
fi
printf 'bumps<<EOF\n%s\nEOF\n' "$bumps" >> "$GITHUB_OUTPUT"
{
  echo 'Pins older than their newest release (dependency, newest, pinned):'
  echo
  # a prefix on every line, which a parameter expansion cannot anchor
  # shellcheck disable=SC2001
  sed 's/^/- /' <<< "$bumps"
} | tee -a "$GITHUB_STEP_SUMMARY"
