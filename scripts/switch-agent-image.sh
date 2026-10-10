#!/usr/bin/env bash
# Point the atc daemon's cloud target at a checked agent image. Run it on the machine that runs the
# daemon, after build-agent-image.sh printed "check passed" for the image:
#
#   bash scripts/switch-agent-image.sh <image> [<atc config file>]
#
# The config file defaults to ~/.config/atc/config.json. It refuses an image the imp host lacks
# and a config without a targets.cloud object. It copies the config to
# <config>.bak-<UTC stamp>-pre-<image>, then sets targets.cloud.image to <image> and
# targets.cloud.guestATC to the image's atc, changes nothing else, and keeps the file's mode 600.
# It never restarts the daemon: it prints the restart command, which a person runs when no session
# needs the daemon. A rollback to an image without atc needs guestATC removed by hand instead;
# docs/runbooks/agent-image.md covers it.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ -z "$1" ]; then
  echo "usage: switch-agent-image.sh <image> [<atc config file>]" >&2
  exit 2
fi
image="$1"
config="${2:-$HOME/.config/atc/config.json}"

if ! jq -e '.targets.cloud | type == "object"' "$config" > /dev/null 2>&1; then
  echo "$config has no targets.cloud object" >&2
  exit 1
fi
current="$(jq -r '.targets.cloud.image // ""' "$config")"
if [ "$current" = "$image" ]; then
  echo "the cloud target already runs $image"
  exit 0
fi
if ! imp image ls --json | jq -e --arg n "$image" 'any(.[]; .name == $n)' > /dev/null; then
  echo "the imp host has no image $image: build it with scripts/build-agent-image.sh first" >&2
  exit 1
fi

backup="$config.bak-$(date -u +%Y%m%dT%H%M%SZ)-pre-$image"
cp -p "$config" "$backup"
echo "backed up $config to $backup"

# other sessions can write the same file, so the edit reads it again and replaces it in one rename
jq --arg image "$image" '.targets.cloud.image = $image | .targets.cloud.guestATC = "/usr/local/bin/atc"' \
  "$config" > "$config.new"
chmod 600 "$config.new"
mv "$config.new" "$config"
echo "set targets.cloud.image to $image (was ${current:-unset})"
echo "the daemon reads its targets at startup: restart it when no session needs it, with"
echo "  systemctl --user restart atc-daemon.service"
