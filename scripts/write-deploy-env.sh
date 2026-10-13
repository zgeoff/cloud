#!/usr/bin/env bash
# Points an env file at the deploy vault: it rewrites each op://cloud/ reference in <env file> to
# op://cloud-deploy/, in place, and keeps every comment, blank line and plain value as it is. The
# prod apply job runs it on each checkout it previews from, because its service account reads
# only the cloud-deploy vault, which holds a copy of each item .env reads under the same name.
#
# A reference to any other vault, or one in another form such as a quoted value, fails the run
# (exit 1) and names its variable, and leaves the
# file unchanged, so the job never resolves a reference the deploy vault does not hold. A missing
# argument is a usage error (exit 2).
#
#   bash scripts/write-deploy-env.sh <env file>
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: write-deploy-env.sh <env file>" >&2
  exit 2
fi
file="$1"

# every line outside a comment that holds op:// anywhere, in any form but VAR=op://cloud/…
foreign="$(grep -vE '^[[:space:]]*#' "$file" | grep -F 'op://' | grep -vE '^[A-Za-z_][A-Za-z0-9_]*=op://cloud/' | cut -d= -f1 || true)"
if [ -n "$foreign" ]; then
  echo "write-deploy-env: a reference outside the cloud vault: $(echo "$foreign" | paste -sd ' ')" >&2
  exit 1
fi

rewritten="$(mktemp "$(dirname "$file")/.deploy-env.XXXXXX")"
trap 'rm -f "$rewritten"' EXIT
sed -E 's#^([A-Za-z_][A-Za-z0-9_]*=)op://cloud/#\1op://cloud-deploy/#' "$file" > "$rewritten"
mv "$rewritten" "$file"
