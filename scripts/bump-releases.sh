#!/usr/bin/env bash
# Opens or updates the bump pull request for each line of BUMPS, the check job's output of
# find-release-bumps.sh lines (`<dependency> <newest> <pinned>...`), by handing each line to
# bump-release.sh. Each bump starts from a clean tree, since a failed pin can leave tracked files
# changed: it resets the checkout hard and removes every untracked file first. Every line runs, so
# one dependency's failure leaves the others' pull requests current; a failed bump prints a GitHub
# Actions error naming its dependency, and once all have run, any failure fails the script. Each
# bump's log sits in its own collapsed group. The release check's bump job runs it from its clone's
# root, with gh signed in to the app's token, a git identity, docker, and NIX_GITHUB_TOKEN:
#
#   BUMPS='atc 4.3.0 4.2.0 4.2.0 4.2.0' bash scripts/bump-releases.sh
set -euo pipefail

: "${BUMPS:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failed=0
while read -r -a bump; do
  echo "::group::${bump[0]} ${bump[1]}"
  # a failed pin can leave tracked files changed; each bump starts from a clean tree
  git reset -q --hard
  git clean -fdq
  # stdin from /dev/null, so a bump never reads the lines still to come
  bash "$here/bump-release.sh" "${bump[@]}" < /dev/null || {
    echo "::error::the ${bump[0]} bump failed"
    failed=1
  }
  echo "::endgroup::"
done <<< "$BUMPS"
exit "$failed"
