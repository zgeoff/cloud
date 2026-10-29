#!/usr/bin/env bash
# Names the record a green pull request run of CI leaves: ci-pass-<tree>-<base tree>, the trees of
# the merge commit under test (HEAD) and of its first parent, the base branch it merged into. It
# writes `name=<name>` to GITHUB_OUTPUT and the name to <file>, which the checks job uploads under
# that name; a push whose tree and gate base match skips its checks (decide-ci-gates.sh).
#
#   bash scripts/write-ci-pass-name.sh <file>
set -euo pipefail

: "${GITHUB_OUTPUT:?}"
if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: write-ci-pass-name.sh <file>" >&2
  exit 2
fi
name="ci-pass-$(git rev-parse 'HEAD^{tree}')-$(git rev-parse 'HEAD^1^{tree}')"
echo "$name" > "$1"
echo "name=$name" >> "$GITHUB_OUTPUT"
