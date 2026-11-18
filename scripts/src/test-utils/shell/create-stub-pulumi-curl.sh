# shellcheck shell=bash
# create_stub_pulumi_curl <bin>: writes <bin>/curl, a stand-in for the two calls that
# install-pulumi-cli.sh makes to get.pulumi.com. It logs each call's argv as a JSON line to
# STUB_TREE/calls. A test states the release files under STUB_TREE/pulumi/:
#
# - `-fsSLO https://get.pulumi.com/releases/sdk/<file>` copies <file> into the working
#   directory under its own name, as -O names it.
# - `-fsSL https://get.pulumi.com/releases/sdk/<file>` prints <file>.
# - A file the tree lacks answers as curl 8.5.0 does for an HTTP 404 with -f: "curl: (22) The
#   requested URL returned error: 404" on stderr, no file written, and exit 22, as checked
#   against the real npm registry on 2026-10-13; which error status get.pulumi.com sends for a
#   missing release is not checked.
# - Any other call ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_pulumi_curl() {
  local bin="$1"
  cat > "$bin/curl" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' curl "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
base=https://get.pulumi.com/releases/sdk/
if [ "$#" = 2 ] && { [ "$1" = -fsSLO ] || [ "$1" = -fsSL ]; } && [[ "$2" == "$base"* ]] &&
  [[ "${2#"$base"}" != */* ]]; then
  file="${2#"$base"}"
  if [ ! -f "$STUB_TREE/pulumi/$file" ]; then
    echo "curl: (22) The requested URL returned error: 404" >&2
    exit 22
  fi
  if [ "$1" = -fsSLO ]; then
    cp "$STUB_TREE/pulumi/$file" "./$file"
  else
    cat "$STUB_TREE/pulumi/$file"
  fi
else
  echo "unexpected: $*" >&2
  exit 97
fi
STUB
  chmod +x "$bin/curl"
}
