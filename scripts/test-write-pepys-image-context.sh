#!/usr/bin/env bash
# Test for write-pepys-image-context.sh: in a copy of the scripts with a small deployment, it checks
# the route table, then writes the host binary, the modules, the two compiled programs and the
# Dockerfile into <dir>; on a route table that differs from the deployment it stops before the
# release download. gh and the build steps of bun are stand-ins, so no case reaches GitHub or
# compiles; the route check runs on the real bun.
#
#   bash scripts/test-write-pepys-image-context.sh
#   CASE='mismatch' bash scripts/test-write-pepys-image-context.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
real_bun="$(command -v bun)"

# write_stub_bun <bin> <log>: a bun that runs `-e` and the route check on the real bun, and for
# `x pepys build` and `build --compile` logs the call and writes a stand-in output
write_stub_bun() {
  local bin="$1" log="$2"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf 'real=%q\nlog=%q\n' "$real_bun" "$log"
    cat << 'STUB'
case "$1" in
  -e | scripts/check-pepys-routes.ts) exec "$real" "$@" ;;
esac
printf '%s\n' "$*" >> "$log"
if [ "$1 $2 $3" = "x pepys build" ]; then
  mkdir -p "$6/ledger"
  echo module > "$6/ledger/0123abcd.wasm"
  echo '{"consumers":[]}' > "$6/consumers.json"
elif [ "$1 $2" = "build --compile" ]; then
  echo program > "${!#}"
else
  echo "unexpected: $*" >&2
  exit 97
fi
STUB
  } > "$bin/bun"
  chmod +x "$bin/bun"
}

# setup_test <tree> <table route>: a repo copy whose deployment has one public receive route,
# /hooks/example, with a route table that names <table route> in its place
setup_test() {
  local tree="$1" table_route="$2" hash
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/release" "$tree/repo/scripts" \
    "$tree/repo/images/pepys" "$tree/repo/deploy/pepys"
  cp "$root/scripts/write-pepys-image-context.sh" "$root/scripts/fetch-pepys-release.sh" \
    "$root/scripts/check-pepys-routes.ts" "$root/scripts/build-pepys-route-table.ts" "$tree/repo/scripts/"
  ln -s "$root/node_modules" "$tree/repo/node_modules"
  cp "$root/images/pepys/Dockerfile" "$tree/repo/images/pepys/"
  cat > "$tree/repo/deploy/pepys/deployment.ts" << 'EOF2'
export const deployment = {
  plugins: [{ sources: [{ name: 'example', live: { kind: 'receive', route: '/hooks/example',
    check: { secretEnv: 'EXAMPLE_SECRET' }, reach: 'public' } }] }],
};
EOF2
  jq -n --arg route "$table_route" \
    '{routes: [{source: "example", route: $route, reach: "public"}], secretVariables: ["EXAMPLE_SECRET"]}' \
    > "$tree/repo/deploy/pepys/ingest-routes.json"

  printf 'host binary for tests\n' > "$tree/release/pepys-host-linux-x64"
  hash="$(sha256sum "$tree/release/pepys-host-linux-x64" | cut -d' ' -f1)"
  echo "$hash  pepys-host-linux-x64" > "$tree/release/SHA256SUMS"
  printf 'PEPYS_RELEASE=v0.4.0\nPEPYS_HOST_ASSET=pepys-host-linux-x64\nPEPYS_HOST_ASSET_SHA256=%s\n' "$hash" \
    > "$tree/repo/images/pepys/versions.env"
  jq -cn --arg asset "$tree/release/pepys-host-linux-x64" --arg sums "$tree/release/SHA256SUMS" \
    '{argv: ["gh", "release", "download", "v0.4.0", "-R", "zgeoff/pepys", "-p", "pepys-host-linux-x64", "-p", "SHA256SUMS", "-D", null],
      downloads: {"pepys-host-linux-x64": $asset, SHA256SUMS: $sums}}' > "$tree/responses"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/responses"
  write_stub_bun "$tree/bin" "$tree/builds"
}

run_write() {
  local tree="$1"
  shift
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$tree/repo/scripts/write-pepys-image-context.sh" "$@"
}

it_writes_the_binaries_the_modules_and_the_dockerfile_into_the_context() {
  local status=0
  create_case_tree
  setup_test "$tree" /hooks/example

  run_write "$tree" "$tree/context" > "$tree/out" 2> "$tree/err" || status=$?

  assert_status 0 "$status"
  diff /dev/null "$tree/err"
  diff - <(cd "$tree/context" && find . -type f | sort) << 'EOF2'
./Dockerfile
./modules/consumers.json
./modules/ledger/0123abcd.wasm
./pepys-api
./pepys-host
./pepys-ingest
EOF2
  diff - "$tree/builds" << EOF2
x pepys build deploy/pepys/deployment.ts --out $tree/context/modules
build --compile --minify --target=bun-linux-x64 deploy/pepys/ingest.ts --outfile $tree/context/pepys-ingest
build --compile --minify --target=bun-linux-x64 deploy/pepys/api.ts --outfile $tree/context/pepys-api
EOF2
}

it_stops_before_the_download_when_the_route_table_differs_from_the_deployment() {
  local status=0
  create_case_tree
  setup_test "$tree" /hooks/other

  run_write "$tree" "$tree/context" > "$tree/out" 2> "$tree/err" || status=$?

  assert_status 1 "$status"
  grep -q '/hooks/example' "$tree/err"
  [ ! -e "$tree/calls" ]
  [ ! -e "$tree/builds" ]
}

it_refuses_to_run_without_a_context_folder() {
  local status=0
  create_case_tree
  setup_test "$tree" /hooks/example

  run_write "$tree" > "$tree/out" 2> "$tree/err" || status=$?

  assert_status 2 "$status"
  diff - "$tree/err" <<< 'usage: write-pepys-image-context.sh <dir>'
  [ ! -e "$tree/calls" ]
}

run_cases
