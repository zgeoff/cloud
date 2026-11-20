#!/usr/bin/env bash
# Run every bats suite of one group in one bats call. A suite is any *.bats file that git tracks, or
# that is untracked and not ignored, so a new suite runs without an edit here, and nothing in
# node_modules, .worktrees or .claude runs. A suite joins a group with a file tag on the line after
# its shebang, `# bats file_tags=suite:<group>`; every converted suite carries one, and the default
# group is scripts:
#
#   bash scripts/run-bats.sh                       # the scripts group
#   bash scripts/run-bats.sh alert-rules           # bun run test:alert-rules
#   CASE='<part of a title>' bash scripts/run-bats.sh alert-rules
#
# It runs bats from the repo root, as `bats --filter-tags suite:<group> --timing
# --print-output-on-failure`, from the bats that bun installs, with BATS_LIB_PATH on the root
# node_modules for bats-support and bats-assert. CASE passes through as --filter. It exits 1 when
# no suite has the group, and bats's own status otherwise.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

group="${1:-scripts}"
if [ "$#" -gt 1 ] || [[ ! "$group" =~ ^[a-z0-9-]+$ ]]; then
  echo "usage: run-bats.sh [group]" >&2
  exit 2
fi

suites=()
while IFS= read -r -d '' file; do
  case "$file" in
    .claude/*) continue ;;
  esac
  [ -f "$file" ] || continue
  if grep -Eq -- "^# bats file_tags=(.*[ ,])?suite:$group([ ,]|\$)" "$file"; then
    suites+=("$file")
  fi
done < <(git ls-files -z --cached --others --exclude-standard --deduplicate -- ':(glob)**/*.bats' | LC_ALL=C sort -z)

if [ "${#suites[@]}" -eq 0 ]; then
  echo "run-bats: no suite in the $group group" >&2
  exit 1
fi

args=(--filter-tags "suite:$group" --timing --print-output-on-failure)
if [ -n "${CASE:-}" ]; then
  args+=(--filter "$CASE")
fi

BATS_LIB_PATH="$PWD/node_modules" exec node_modules/.bin/bats "${args[@]}" "${suites[@]}"
