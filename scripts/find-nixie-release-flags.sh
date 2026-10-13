#!/usr/bin/env bash
# Print the review flags of a nixie bump, one per line, from the release notes of the pinned
# release, the target release and every release between them:
#
# - `migrations` when the `## Migrations` section of the target or of a release between is not
#   empty, or is missing. Empty means its only text, besides blank lines, is the one sentence
#   nixie writes for a release without one ("This release adds no migration since vX.Y.Z."); a
#   blank section is not empty. Every release counts, because each lists only its own migrations.
# - `sandbox-images-changed` when the sandbox images under `## Images`, every image except nixie
#   and nixie-web, differ between the pinned release and the target. Until impd adds them itself
#   (GEO-548), a person adds changed sandbox images to impd before the rollout.
#
#   bash scripts/find-nixie-release-flags.sh <pinned notes> <target notes> [<notes between>...]
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: find-nixie-release-flags.sh <pinned notes> <target notes> [<notes between>...]" >&2
  exit 2
fi
pinned="$1"
target="$2"

# read_section <heading> <notes>: prints the section's lines up to the next heading
read_section() {
  awk -v heading="$1" '/^## / { section = $0; next } section == heading' "$2"
}

# read_sandbox_images <notes>: prints the sorted image references under `## Images`, except nixie's
# own two images
read_sandbox_images() {
  read_section '## Images' "$1" | grep -E '^- `' |
    grep -vE '^- `ghcr\.io/zgeoff/(nixie|nixie-web)@' | sort || true
}

for notes in "${@:2}"; do
  if ! grep -qx '## Migrations' "$notes"; then
    echo migrations
    break
  fi
  # the section's text without its blank lines, read whole rather than through grep -q: under
  # pipefail, grep -q's early exit fails the pipe's writer on a long section. Only the one
  # sentence counts as empty; a blank section or any other text flags migrations.
  text="$(read_section '## Migrations' "$notes" | grep -v '^[[:space:]]*$' || true)"
  if [[ ! "$text" =~ ^This\ release\ adds\ no\ migration\ since\ v[0-9]+\.[0-9]+\.[0-9]+\.$ ]]; then
    echo migrations
    break
  fi
done

if ! cmp -s <(read_sandbox_images "$pinned") <(read_sandbox_images "$target"); then
  echo sandbox-images-changed
fi
