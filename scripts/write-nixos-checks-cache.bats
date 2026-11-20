#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for write-nixos-checks-cache.sh: against the docker stand-in
# (scripts/src/test-utils/shell/create-stub-checks-docker.sh), which answers the closure query and the
# path-info from files each case writes and copies paths into a cache folder as narinfo files, it
# caches and lists the closure's outputs that cache.nixos.org did not sign, leaves the derivations
# out, puts the new cache in place of the restored one, writes saved=false for paths the restored cache already lists and for a cache over its cap,
# and refuses a folder that already exists. Each case runs the script under `env -i` and compares
# its whole stdout, stderr, GITHUB_OUTPUT, cache folder and docker call log.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-checks-docker.sh'
  load 'nix-image.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/write-nixos-checks-cache.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
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

@test "it caches and lists the outputs that cache nixos org did not sign" {
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
  # result came unsigned from an earlier run's cache; the kernel references glibc, which the cache
  # needs a narinfo for during the copy
  cat > "$tree/path-info" << 'EOF'
{"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel":{"narHash":"sha256-IlLUt4yU6Mes5OMxe3i9/mS8jjlwpk620vfCpEPAw/w=","narSize":120,"references":["/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-glibc"],"signatures":[],"ultimate":true},
 "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-glibc":{"narHash":"sha256-6bxJTBkLnsFj4K3gXHcI8ZAxwSKfgD6cTUHlwmpTVSs=","narSize":240,"references":[],"signatures":["cache.nixos.org-1:c2lnbmF0dXJl"],"ultimate":false},
 "/nix/store/cccccccccccccccccccccccccccccccc-lantern-check":{"narHash":"sha256-ANwP7nl3mMsVNAy23Y3qgNEDqHddtM4jDRVJhyOsnyk=","narSize":360,"references":["/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel","/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-glibc"],"signatures":null,"ultimate":false}}
EOF
  # an older cache, restored where actions/cache restores it
  mkdir "$tree/restored"
  printf '/nix/store/dddddddddddddddddddddddddddddddd-lantern-kernel\n' > "$tree/restored/paths"
  printf 'StorePath: /nix/store/dddddddddddddddddddddddddddddddd-lantern-kernel\n' > "$tree/restored/dddddddddddddddddddddddddddddddd.narinfo"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_CLOSURE="$tree/closure" STUB_PATH_INFO="$tree/path-info" GITHUB_OUTPUT="$tree/output" \
    bash "$script" "$tree/derivations" "$tree/restored" "$tree/cache"

  refute_stderr

  # shellcheck disable=SC2001 # a regex mask, which ${variable//search/replace} cannot express

  output="$(sed -E 's/ in [0-9]+ MB\.$/ in SIZE MB./' <<< "$output")"
  assert_output 'The cache holds 2 paths in SIZE MB.'
  run -0 diff - "$tree/output" <<< 'saved=true'
  refute [ -e "$tree/cache" ]
  refute [ -L "$tree/cache" ]
  run -0 diff - "$tree/restored/paths" << 'EOF'
/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel
/nix/store/cccccccccccccccccccccccccccccccc-lantern-check
EOF
  ls -A "$tree/restored" > "$tree/cache-files"
  run -0 diff - "$tree/cache-files" << 'EOF'
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.narinfo
cccccccccccccccccccccccccccccccc.narinfo
nix-cache-info
paths
EOF
  run -0 diff - "$tree/calls" << EOF
["docker","run","--rm","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix-store","-qR","--include-outputs","/nix/store/00000000000000000000000000000000-lantern-check.drv"]
["docker","run","--rm","-i","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command","path-info","--json","--stdin"]
["docker","run","--rm","-i","-v","cloud-nixos-checks-store:/nix","-v","$tree/cache:/cache","$NIX_IMAGE","nix","--extra-experimental-features","nix-command","copy","--no-recursive","--stdin","--to","file:///cache?compression=zstd"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it does not save again the paths the restored cache lists" {
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-lantern-check.drv\n' > "$tree/derivations"
  printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel\n' > "$tree/closure"
  printf '{"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel":{"signatures":[]}}\n' > "$tree/path-info"
  mkdir "$tree/restored"
  printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel\n' > "$tree/restored/paths"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_CLOSURE="$tree/closure" STUB_PATH_INFO="$tree/path-info" GITHUB_OUTPUT="$tree/output" \
    bash "$script" "$tree/derivations" "$tree/restored" "$tree/cache"

  assert_output 'The cache holds the paths this build needed, so it was not saved again.'
  refute_stderr

  run -0 diff - "$tree/output" <<< 'saved=false'
  run -0 diff - "$tree/calls" << EOF
["docker","run","--rm","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix-store","-qR","--include-outputs","/nix/store/00000000000000000000000000000000-lantern-check.drv"]
["docker","run","--rm","-i","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command","path-info","--json","--stdin"]
EOF
}

@test "it does not save a cache over its cap" {
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-lantern-check.drv\n' > "$tree/derivations"
  printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel\n' > "$tree/closure"
  printf '{"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern-kernel":{"signatures":[]}}\n' > "$tree/path-info"

  # du rounds any file up to a whole megabyte, so a cap of 0 holds no cache
  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_CLOSURE="$tree/closure" STUB_PATH_INFO="$tree/path-info" GITHUB_OUTPUT="$tree/output" \
    NIXOS_CHECKS_CACHE_MAX_MB=0 \
    bash "$script" "$tree/derivations" "$tree/restored" "$tree/cache"

  assert_output 'The cache came to 1 MB, over its cap of 0 MB, so it was not saved.'
  refute_stderr

  run -0 diff - "$tree/output" <<< 'saved=false'
}

@test "it refuses a cache folder that already exists" {
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-lantern-check.drv\n' > "$tree/derivations"
  mkdir "$tree/cache"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    GITHUB_OUTPUT="$tree/output" \
    bash "$script" "$tree/derivations" "$tree/restored" "$tree/cache"

  refute_output
  assert_stderr 'usage: write-nixos-checks-cache.sh <derivations> <restored> <dir>, a folder that does not exist yet'

  run -0 diff /dev/null "$tree/output"
  run -0 diff /dev/null "$tree/calls"
}
