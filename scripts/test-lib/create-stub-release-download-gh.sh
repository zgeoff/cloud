# shellcheck shell=bash
# create_stub_release_download_gh <bin>: writes <bin>/gh, a stand-in for the one call that
# fetch-atc-release.sh makes, `gh release download <tag> -R <owner/repo> -p <asset>… -D <dir>`.
# It logs each call's argv as a JSON line to STUB_TREE/calls. A test states a release as a
# directory STUB_TREE/releases/<owner/repo>/<tag>/ holding its assets:
#
# - each -p names an asset by its exact name, which the stand-in copies into <dir>, as gh does
#   for a pattern that matches one asset; it models no glob;
# - a release the tree lacks answers as the real gh does: "release not found" on stderr and
#   exit 1, the answer test-start-stub-github-api.sh pins against the real gh, with nothing
#   written to <dir>;
# - a named asset the release lacks, and any other call, end with exit 97 and
#   "unexpected: <argv>" on stderr.
create_stub_release_download_gh() {
  local bin="$1"
  cat > "$bin/gh" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' gh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
argv="$*"
if [ "$#" -lt 7 ] || [ "$1" != release ] || [ "$2" != download ] || [ "$4" != -R ]; then
  echo "unexpected: $argv" >&2
  exit 97
fi
release="$STUB_TREE/releases/$5/$3"
shift 5
assets=()
while [ "$#" -gt 2 ] && [ "$1" = -p ]; do
  assets+=("$2")
  shift 2
done
if [ "$#" != 2 ] || [ "$1" != -D ] || [ "${#assets[@]}" = 0 ]; then
  echo "unexpected: $argv" >&2
  exit 97
fi
dir="$2"
if [ ! -d "$release" ]; then
  echo "release not found" >&2
  exit 1
fi
for asset in "${assets[@]}"; do
  if [ ! -f "$release/$asset" ]; then
    echo "unexpected: $argv" >&2
    exit 97
  fi
done
for asset in "${assets[@]}"; do
  cp "$release/$asset" "$dir/$asset"
done
STUB
  chmod +x "$bin/gh"
}
