#!/usr/bin/env bash
# Test for write-nixos-checks-cache.sh: against the docker stand-in
# (test-support/shell/create-stub-checks-docker.sh), which answers the closure query and the
# path-info from files each case writes and copies paths into a cache folder as narinfo files, it
# caches and lists the closure's outputs that cache.nixos.org did not sign, leaves the derivations
# out, writes saved=false for paths the restored cache already lists and for a cache over its cap,
# and refuses a folder that already exists. Each case runs the script under `env -i` and compares
# its whole stdout, stderr, GITHUB_OUTPUT, cache folder and docker call log.
#
#   bash scripts/test-write-nixos-checks-cache.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-checks-docker.sh"
source "$(dirname "${BASH_SOURCE[0]}")/nix-image.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/write-nixos-checks-cache.sh"

it_caches_and_lists_the_outputs_that_cache_nixos_org_did_not_sign() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-lantern-check.drv\n' > "$tree/derivations"
  cat > "$tree/closure" << 'EOF'
/nix/store/00000000000000000000000000000000-lantern-check.drv
/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel
/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-glibc
/nix/store/cccccccccccccccccccccccccccccccc-lantern-check
EOF
  # the shape nix 2.35.2's `nix path-info --json` prints: an object keyed by store path; the
  # kernel built here has no signature, glibc came signed from cache.nixos.org, and the check's
  # result came unsigned from an earlier run's cache
  cat > "$tree/path-info" << 'EOF'
{"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel":{"signatures":[],"ultimate":true},
 "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-glibc":{"signatures":["cache.nixos.org-1:c2lnbmF0dXJl"],"ultimate":false},
 "/nix/store/cccccccccccccccccccccccccccccccc-lantern-check":{"signatures":null,"ultimate":false}}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_CLOSURE="$tree/closure" STUB_PATH_INFO="$tree/path-info" GITHUB_OUTPUT="$tree/output" \
    bash "$script" "$tree/derivations" "$tree/restored" "$tree/cache" > "$tree/out" 2> "$tree/err" || status=$?

  sed -E 's/ in [0-9]+ MB\.$/ in SIZE MB./' "$tree/out" > "$tree/out-masked"
  diff - "$tree/out-masked" <<< 'The cache holds 2 paths in SIZE MB.'
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< 'saved=true'
  diff - "$tree/cache/paths" << 'EOF'
/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel
/nix/store/cccccccccccccccccccccccccccccccc-lantern-check
EOF
  ls -A "$tree/cache" > "$tree/cache-files"
  diff - "$tree/cache-files" << 'EOF'
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.narinfo
cccccccccccccccccccccccccccccccc.narinfo
nix-cache-info
paths
EOF
  diff - "$tree/calls" << EOF
["docker","run","--rm","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix-store","-qR","--include-outputs","/nix/store/00000000000000000000000000000000-lantern-check.drv"]
["docker","run","--rm","-i","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command","path-info","--json","--stdin"]
["docker","run","--rm","-i","-v","cloud-nixos-checks-store:/nix","-v","$tree/cache:/cache","$NIX_IMAGE","nix","--extra-experimental-features","nix-command","copy","--no-recursive","--stdin","--to","file:///cache?compression=zstd"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 0 "$status"
}

it_does_not_save_again_the_paths_the_restored_cache_lists() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-lantern-check.drv\n' > "$tree/derivations"
  printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel\n' > "$tree/closure"
  printf '{"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel":{"signatures":[]}}\n' > "$tree/path-info"
  mkdir "$tree/restored"
  printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel\n' > "$tree/restored/paths"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_CLOSURE="$tree/closure" STUB_PATH_INFO="$tree/path-info" GITHUB_OUTPUT="$tree/output" \
    bash "$script" "$tree/derivations" "$tree/restored" "$tree/cache" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'The cache holds the paths this build needed, so it was not saved again.'
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< 'saved=false'
  diff - "$tree/calls" << EOF
["docker","run","--rm","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix-store","-qR","--include-outputs","/nix/store/00000000000000000000000000000000-lantern-check.drv"]
["docker","run","--rm","-i","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command","path-info","--json","--stdin"]
EOF
  assert_status 0 "$status"
}

it_does_not_save_a_cache_over_its_cap() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-lantern-check.drv\n' > "$tree/derivations"
  printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel\n' > "$tree/closure"
  printf '{"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel":{"signatures":[]}}\n' > "$tree/path-info"

  # du rounds any file up to a whole megabyte, so a cap of 0 holds no cache
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_CLOSURE="$tree/closure" STUB_PATH_INFO="$tree/path-info" GITHUB_OUTPUT="$tree/output" \
    NIXOS_CHECKS_CACHE_MAX_MB=0 \
    bash "$script" "$tree/derivations" "$tree/restored" "$tree/cache" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'The cache came to 1 MB, over its cap of 0 MB, so it was not saved.'
  diff /dev/null "$tree/err"
  diff - "$tree/output" <<< 'saved=false'
  assert_status 0 "$status"
}

it_refuses_a_cache_folder_that_already_exists() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-lantern-check.drv\n' > "$tree/derivations"
  mkdir "$tree/cache"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    GITHUB_OUTPUT="$tree/output" \
    bash "$script" "$tree/derivations" "$tree/restored" "$tree/cache" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: write-nixos-checks-cache.sh <derivations> <restored> <dir>, a folder that does not exist yet'
  diff /dev/null "$tree/output"
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

# setup_test <tree>: the docker stand-in in <tree>/bin, the home and temp folders the script runs
# with, and the empty GITHUB_OUTPUT the runner provides.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  # boot data: the runner creates the file before a step runs
  : > "$tree/output"
  create_stub_checks_docker "$tree/bin"
}

run_cases
