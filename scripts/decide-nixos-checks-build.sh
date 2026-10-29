#!/usr/bin/env bash
# Decides whether the NixOS checks workflow builds the checks whose derivation paths <derivations>
# lists (run-nixos-checks.sh --derivations writes it). It writes `key=<key>` and `needed=true` or
# `needed=false` to GITHUB_OUTPUT. The key hashes the derivation paths with the git blob of each
# file that decides how the workflow builds them, at GITHUB_SHA: a run that builds the checks and
# passes uploads an artifact named nixos-checks-<key>. Nix builds a derivation path to the same
# result wherever it runs, so a later run whose key names an unexpired artifact of this repository
# skips the build, and says which run built it on stdout and in GITHUB_STEP_SUMMARY. A run on a
# commit whose workflow or build scripts differ gets another key. A dispatch with FORCE=true always
# builds. A gh failure fails the script with gh's error and writes no answer, so the job fails
# rather than skipping the checks.
#
#   [FORCE=true] bash scripts/decide-nixos-checks-build.sh <derivations>
set -euo pipefail

: "${GITHUB_SHA:?}" "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}" "${GITHUB_SERVER_URL:?}" "${GITHUB_REPOSITORY:?}"
if [ "$#" -ne 1 ] || [ ! -s "$1" ]; then
  echo "usage: decide-nixos-checks-build.sh <derivations>, a file of one derivation path per line" >&2
  exit 2
fi

build_files=(
  .bun-version
  .github/workflows/nixos-checks.yml
  package.json
  scripts/decide-nixos-checks-build.sh
  scripts/nix-image.sh
  scripts/open-kvm.sh
  scripts/run-nixos-checks.sh
)
key="$({
  cat "$1"
  git ls-tree "$GITHUB_SHA" -- "${build_files[@]}"
} | sha256sum | cut -d' ' -f1)"

if [ "${FORCE:-}" = true ]; then
  printf 'key=%s\nneeded=true\n' "$key" >> "$GITHUB_OUTPUT"
  exit 0
fi
run="$(gh api -X GET "repos/{owner}/{repo}/actions/artifacts" -f name="nixos-checks-$key" -f per_page=100 \
  --jq '[.artifacts[] | select(.expired == false and .workflow_run.head_repository_id == .workflow_run.repository_id)][0].workflow_run.id // empty')"
if [ -n "$run" ]; then
  printf 'key=%s\nneeded=false\n' "$key" >> "$GITHUB_OUTPUT"
  echo "Run $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$run built and passed these checks' derivations, so the checks did not run." | tee -a "$GITHUB_STEP_SUMMARY"
else
  printf 'key=%s\nneeded=true\n' "$key" >> "$GITHUB_OUTPUT"
fi
