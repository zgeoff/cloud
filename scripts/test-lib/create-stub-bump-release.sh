# shellcheck shell=bash
# create_stub_bump_release <dir>: writes <dir>/bump-release.sh, a stand-in for
# scripts/bump-release.sh that bump-releases.sh runs once per bump, so a test copies
# bump-releases.sh into <dir> beside it. It opens no pull request and runs no gh, docker or pin.
#
# - With fewer than three arguments it prints the real script's usage on stderr and exits 2.
# - Otherwise it logs its argv as a JSON line to STUB_TREE/calls, then the working tree it found as
#   the line {"status":"<git status --porcelain>"}, so a test sees whether the bump started from a
#   clean tree. It leaves the tree dirty, as a failed pin can: it appends a line to the tracked file
#   pinned.txt and writes the untracked file left-over.txt. It prints "bumped <dependency>".
# - When STUB_FAILING (space-separated dependencies) names the dependency, it then prints
#   "the <dependency> pin failed" on stderr and exits 1.
#
# It reads its stdin to the end and logs it as {"stdin":"<what it read>"}, so a test sees whether
# its caller left it the lines still to come.
create_stub_bump_release() {
  local dir="$1"
  cat > "$dir/bump-release.sh" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -lt 3 ]; then
  echo "usage: bump-release.sh <dependency> <version> <pinned version>..." >&2
  exit 2
fi
printf '%s\0' bump-release.sh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
jq -cn --arg status "$(git status --porcelain)" '{status: $status}' >> "$STUB_TREE/calls"
jq -cn --arg stdin "$(cat)" '{stdin: $stdin}' >> "$STUB_TREE/calls"
echo "changed by the $1 bump" >> pinned.txt
echo "left by the $1 bump" > left-over.txt
echo "bumped $1"
if [[ " ${STUB_FAILING:-} " == *" $1 "* ]]; then
  echo "the $1 pin failed" >&2
  exit 1
fi
STUB
  chmod +x "$dir/bump-release.sh"
}
