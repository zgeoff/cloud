#!/usr/bin/env bash
# Run every shell suite of one group. A suite is any file named test-*.sh that git tracks, or that
# is untracked and not ignored, so a new suite runs without an edit here, and nothing in
# node_modules, .worktrees or .claude runs. A suite joins a group other than the default, scripts,
# with a line `# shell-suite: <group>` in the comment block at its top:
#
#   bash scripts/run-shell-suites.sh                       # the scripts group: bun run test:scripts
#   bash scripts/run-shell-suites.sh atc-gateway-fixture   # under with-fixture-images.sh
#   CASE='<part of a title>' bash scripts/run-shell-suites.sh
#
# It runs every suite of the group, in path order, each as `bash <suite>` from the repo root with
# the caller's environment (CASE among it), and prints `== <suite>` before each. It keeps going
# after a failed suite, then names the failed ones on stderr and exits 1. It also exits 1 when the
# group has no suite.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

group="${1:-scripts}"
if [ "$#" -gt 1 ] || [[ ! "$group" =~ ^[a-z0-9-]+$ ]]; then
  echo "usage: run-shell-suites.sh [group]" >&2
  exit 2
fi

# the group a suite names in its leading comment block, or scripts when it names none
read_group() {
  local found
  found="$(sed -n '/^[^#]/q; s/^# shell-suite: \([a-z0-9-]*\)$/\1/p' "$1")"
  echo "${found:-scripts}"
}

suites=()
while IFS= read -r -d '' file; do
  case "$file" in
    .claude/*) continue ;;
  esac
  [ -f "$file" ] || continue
  if [ "$(read_group "$file")" = "$group" ]; then
    suites+=("$file")
  fi
done < <(git ls-files -z --cached --others --exclude-standard --deduplicate -- ':(glob)**/test-*.sh' | LC_ALL=C sort -z)

if [ "${#suites[@]}" -eq 0 ]; then
  echo "run-shell-suites: no suite in the $group group" >&2
  exit 1
fi

failed=()
for suite in "${suites[@]}"; do
  echo "== $suite"
  bash "$suite" || failed+=("$suite")
done

echo "${#suites[@]} suites, ${#failed[@]} failed"
if [ "${#failed[@]}" -gt 0 ]; then
  printf 'run-shell-suites: %s failed\n' "${failed[@]}" >&2
  exit 1
fi
