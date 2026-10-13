#!/usr/bin/env bash
# Sets the checkout's git identity to a GitHub App's bot user, so the release check's bump commits
# carry the app as their author: user.name is "<app slug>[bot]", and user.email the bot's noreply
# address, which carries the bot user's id. It reads the id with gh, and a gh failure fails it
# before it changes any setting. The release check workflow's bump job runs it in its checkout with
# the app's token:
#
#   bash scripts/set-release-bot-identity.sh <app slug>
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: set-release-bot-identity.sh <app slug>" >&2
  exit 2
fi
slug="$1"

id="$(gh api "users/$slug%5Bbot%5D" --jq .id)"
git config user.name "${slug}[bot]"
git config user.email "$id+${slug}[bot]@users.noreply.github.com"
