#!/usr/bin/env bash
# Refuse a host switch whose impd the running nixie cannot speak. switch-geoffcloud.sh runs it
# before the build and again before the activation, with the configuration.nix of the commit it
# switches to and the image of each nixie pod that the cluster runs:
#
#   bash scripts/check-nixie-impd-major.sh <configuration.nix> [<nixie image>...]
#
# The impd release is the imp-host image's tag, which the imp release bump moves with the imp
# module. nixie talks to impd through its imp client, whose checkServer refuses an impd of another
# major release, and nixie's start then retries for ever while the host reports healthy. The image
# bundles the client, so the check reads its version from bun.lock at the nixie release's tag,
# through gh. The client is @impz/client from nixie 0.35.1 and @zgeoff/imp-client before it. A lock
# that names both takes @impz/client's version, because the rename replaced the old package:
# nixie's sandbox-imp adapter imports only @impz/client from v0.35.1, so an @zgeoff/imp-client entry
# beside it is a leftover that nixie does not talk to impd through.
# It prints one line and exits 0 when every nixie pod accepts the impd major. It exits 1 when one
# does not, when no nixie pod runs, when the pin or an image holds no release version, or when the
# lock names no one client version; a gh failure stops it with gh's exit code.
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: check-nixie-impd-major.sh <configuration.nix> [<nixie image>...]" >&2
  exit 2
fi
config="$1"
images=("${@:2}")
version='([0-9]+)\.[0-9]+\.[0-9]+'

if [ ! -f "$config" ]; then
  echo "$config is missing, so the switch has no impd pin to compare" >&2
  exit 1
fi
# the one services.imp.image line, as the imp release bump writes it
impd="$(sed -nE "s/^ +image = \"ghcr\.io\/zgeoff\/imp-host:($version)@sha256:[0-9a-f]{64}\";\$/\\1/p" "$config")"
if [[ ! "$impd" =~ ^$version$ ]]; then
  echo "$config pins no imp-host release image" >&2
  exit 1
fi
impd_major="${BASH_REMATCH[1]}"

# accepts_impd_major <nixie version> <client version>: exits 0 when that nixie speaks impd_major.
# nixie takes impd's major from its client, except that nixie 0.28.0 and later accept impd 2 with
# a 1.x client: impd 2 renamed imp's CLI and kept impd 1.6's wire API (RENAMED_IMPD in nixie's
# adapters/sandbox-imp/src/build-imp-port.ts, absent at v0.27.2).
accepts_impd_major() {
  local client_major="${2%%.*}"
  if [ "$client_major" = "$impd_major" ]; then return 0; fi
  [ "$client_major" = 1 ] && [ "$impd_major" = 2 ] &&
    printf '0.28.0\n%s\n' "$1" | sort -V -C
}

# a nixie rollout recreates its one pod, so between the old pod's end and the new pod's start no
# nixie runs, and the switch cannot tell which client the next one holds
if [ "${#images[@]}" = 0 ]; then
  echo "no nixie pod runs, so the switch cannot tell which impd it speaks; wait for its" \
    "rollout (kubectl -n nixie rollout status statefulset nixie)" >&2
  exit 1
fi
found=()
for image in "${images[@]}"; do
  if [[ ! "$image" =~ ^ghcr\.io/zgeoff/nixie:($version)(@sha256:[0-9a-f]{64})?$ ]]; then
    echo "a nixie pod runs '$image', which is no nixie release image" >&2
    exit 1
  fi
  nixie="${BASH_REMATCH[1]}"
  lock="$(gh api -H 'Accept: application/vnd.github.raw' "repos/zgeoff/nixie/contents/bun.lock?ref=v$nixie")"
  # the lock's packages entry, `"@impz/client": ["@impz/client@X.Y.Z", …`, of the first client
  # package that the lock names
  clients=""
  for package in @impz/client @zgeoff/imp-client; do
    clients="$(grep -oE "\"$package\": \[\"$package@$version\"" <<< "$lock" |
      sed -E 's/.*@([0-9.]+)"$/\1/' || true)"
    if [ -n "$clients" ]; then break; fi
  done
  if [[ ! "$clients" =~ ^$version$ ]]; then
    echo "nixie $nixie's bun.lock names no one @impz/client or @zgeoff/imp-client version" >&2
    exit 1
  fi
  if ! accepts_impd_major "$nixie" "$clients"; then
    echo "the switch would run impd $impd, but a nixie pod runs nixie $nixie, whose imp-client" \
      "$clients refuses an impd of another major; deploy a nixie that speaks impd $impd_major" \
      "first (docs/runbooks/workflows.md, Switch the host)" >&2
    exit 1
  fi
  found+=("nixie $nixie (imp-client $clients)")
done
echo "== impd $impd on the host, ${found[*]} in the cluster"
