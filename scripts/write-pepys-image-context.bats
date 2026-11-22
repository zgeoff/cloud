#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for write-pepys-image-context.sh: in a copy of the scripts with a small deployment, it checks
# the route table, then writes the host binary, the modules, the two compiled programs and the
# Dockerfile into <dir>; on a route table that differs from the deployment it stops before the
# release download. gh, `pepys build` and the compile script are stand-ins, so no case reaches
# GitHub or compiles; the route check runs on the real bun.
#
#   bash scripts/run-bats.sh
#   CASE='mismatch' bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-gh.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  real_bun="$(command -v bun)"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# write_stub_bun <bin> <log>: a bun that runs `-e` and the route check on the real bun, and for
# deploy/pepys/compile-entries.ts logs the call and writes stand-in programs
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
printf 'bun %s\n' "$*" >> "$log"
if [ "$#" = 2 ] && [ "$1" = deploy/pepys/compile-entries.ts ]; then
  echo program > "$2/pepys-ingest"
  echo program > "$2/pepys-api"
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
  write_stub_pepys "$tree/repo/deploy/pepys/node_modules/.bin" "$tree/builds"
}

# write_stub_pepys <bin> <log>: the deployment's pepys, which logs the call with its folder and
# writes one module and consumers.json for `build deployment.ts --out <dir>`
write_stub_pepys() {
  local bin="$1" log="$2"
  mkdir -p "$bin"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf 'log=%q\n' "$log"
    cat << 'STUB'
printf 'pepys %s in %s\n' "$*" "$(basename "$PWD")" >> "$log"
[ "$1 $2 $3" = "build deployment.ts --out" ] || exit 97
mkdir -p "$4/ledger"
echo module > "$4/ledger/0123abcd.wasm"
echo '{"consumers":[]}' > "$4/consumers.json"
STUB
  } > "$bin/pepys"
  chmod +x "$bin/pepys"
}

run_write() {
  local tree="$1"
  shift
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$tree/repo/scripts/write-pepys-image-context.sh" "$@"
}

@test "it writes the binaries the modules and the dockerfile into the context" {
  local context
  setup_test "$tree" /hooks/example

  run -0 --separate-stderr run_write "$tree" "$tree/context"

  refute_stderr
  context="$(cd "$tree/context" && pwd)"

  run -0 diff - <(cd "$tree/context" && find . -type f | sort) << 'EOF2'
./Dockerfile
./modules/consumers.json
./modules/ledger/0123abcd.wasm
./pepys-api
./pepys-host
./pepys-ingest
EOF2
  run -0 diff - "$tree/builds" << EOF2
pepys build deployment.ts --out $context/modules in pepys
bun deploy/pepys/compile-entries.ts $context
EOF2
}

@test "it stops before the download when the route table differs from the deployment" {
  setup_test "$tree" /hooks/other

  run -1 --separate-stderr run_write "$tree" "$tree/context"

  assert_stderr --partial '/hooks/example'
  refute [ -e "$tree/calls" ]
  refute [ -L "$tree/calls" ]
  refute [ -e "$tree/builds" ]
  refute [ -L "$tree/builds" ]
}

@test "it stops before the download when the route table leaves out a sender route" {
  setup_test "$tree" /hooks/example
  cat > "$tree/repo/deploy/pepys/deployment.ts" << 'EOF2'
export const deployment = {
  plugins: [{ sources: [{ name: 'example', live: { kind: 'receive', route: '/hooks/example',
    check: { secretEnv: 'EXAMPLE_SECRET' }, reach: 'public',
    senderRoutes: [{ route: '/relayed/hooks/example', sender: { kind: 'imp-identity' } }] } }] }],
};
EOF2

  run -1 --separate-stderr run_write "$tree" "$tree/context"

  assert_stderr --partial '"route": "/relayed/hooks/example"'
  refute [ -e "$tree/calls" ]
  refute [ -L "$tree/calls" ]
  refute [ -e "$tree/builds" ]
  refute [ -L "$tree/builds" ]
}

@test "it stops before any step when the deployment is not installed" {
  setup_test "$tree" /hooks/example
  rm -r "$tree/repo/deploy/pepys/node_modules"

  run -1 --separate-stderr run_write "$tree" "$tree/context"

  assert_stderr --partial 'deploy/pepys is not installed'
  refute [ -e "$tree/calls" ]
  refute [ -L "$tree/calls" ]
  refute [ -e "$tree/builds" ]
  refute [ -L "$tree/builds" ]
}

@test "it refuses to run without a context folder" {
  setup_test "$tree" /hooks/example

  run -2 --separate-stderr run_write "$tree"

  assert_stderr 'usage: write-pepys-image-context.sh <dir>'

  [ ! -e "$tree/calls" ]
}
