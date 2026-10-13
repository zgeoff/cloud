# shellcheck shell=bash
# create_stub_release_curl <bin>: writes <bin>/curl, a stand-in for the npm registry calls that
# bump-release.sh makes for an auto-mode release. It logs each call's argv as a JSON line to
# STUB_TREE/calls. A test states the registry as files under STUB_TREE/npm/<package>/:
#
# - `-fsSL https://registry.npmjs.org/<package>/<version>` prints <version>.json, the version's
#   metadata as the registry returns it.
# - `-fsSL -o <file> https://registry.npmjs.org/<package>/-/<tarball>` copies <tarball> to <file>.
# - A file the tree lacks answers as curl 8.5.0 does for the registry's 404: "curl: (22) The
#   requested URL returned error: 404" on stderr, no output file, and exit 22, checked against the
#   real registry on 2026-10-13.
# - Any other call ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_release_curl() {
  local bin="$1"
  cat > "$bin/curl" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' curl "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
registry=https://registry.npmjs.org/
# answer <file>: prints the path of the registry file, or fails as curl does on a 404
answer() {
  if [ ! -f "$STUB_TREE/npm/$1" ]; then
    echo "curl: (22) The requested URL returned error: 404" >&2
    exit 22
  fi
}
if [ "$#" = 2 ] && [ "$1" = -fsSL ] && [[ "$2" == "$registry"*/* ]] && [[ "$2" != */-/* ]]; then
  path="${2#"$registry"}"
  answer "$path.json"
  cat "$STUB_TREE/npm/$path.json"
elif [ "$#" = 4 ] && [ "$1" = -fsSL ] && [ "$2" = -o ] && [[ "$4" == "$registry"*/-/* ]]; then
  path="${4#"$registry"}"
  path="${path%%/-/*}/${path##*/}"
  answer "$path"
  cp "$STUB_TREE/npm/$path" "$3"
else
  echo "unexpected: $*" >&2
  exit 97
fi
STUB
  chmod +x "$bin/curl"
}
