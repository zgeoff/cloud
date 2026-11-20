#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-checks-docker.sh: the docker stand-in answers the nix eval, path-info and
# build that run-nixos-checks.sh runs and the closure query, path-info and copy to a cache that
# write-nixos-checks-cache.sh runs, copies what the path-info call mounts at /src, logs every
# call, and fails closed on any other call. No nix runs here; the stand-in's exit 1 for a failed
# eval, path-info or build is the one its header records from one-off checks against nix 2.35.2.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-checks-docker.sh'
  load '../../../nix-image.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_checks_docker "$tree/bin"
}

@test "it prints the check names without a trailing newline for an eval" {
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CHECKS=$'atc-daemon\nimpd-restore\n' \
    docker run --rm "$NIX_IMAGE" nix eval --raw 'path:/src?dir=nixos#checks.x86_64-linux' --apply builtins.attrNames > "$tree/out" 2> "$tree/err"

  printf 'atc-daemon\nimpd-restore\n' | cmp - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"$NIX_IMAGE\",\"nix\",\"eval\",\"--raw\",\"path:/src?dir=nixos#checks.x86_64-linux\",\"--apply\",\"builtins.attrNames\"]"
}

@test "it fails an eval with the set error and exit 1" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CHECKS=atc-daemon \
    STUB_EVAL_ERROR="error: undefined variable 'x'" \
    docker run --rm "$NIX_IMAGE" nix eval --raw 'path:/src?dir=nixos#checks.x86_64-linux' --apply builtins.attrNames

  refute_output
  assert_stderr "error: undefined variable 'x'"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"$NIX_IMAGE\",\"nix\",\"eval\",\"--raw\",\"path:/src?dir=nixos#checks.x86_64-linux\",\"--apply\",\"builtins.attrNames\"]"
}

@test "it copies the source and prints each checks derivation for a path info" {
  setup_test "$tree"
  mkdir -p "$tree/src/nixos"
  echo '{ }' > "$tree/src/nixos/flake.nix"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_SOURCE_SAW="$tree/saw" \
    docker run --rm -v "$tree/src:/src:ro" "$NIX_IMAGE" nix path-info --derivation \
    'path:/src?dir=nixos#checks.x86_64-linux.atc-daemon' 'path:/src?dir=nixos#checks.x86_64-linux.impd-restore'

  diff -r "$tree/src" "$tree/saw"
  assert_output - << 'EOF'
/nix/store/00000000000000000000000000000000-atc-daemon.drv
/nix/store/00000000000000000000000000000000-impd-restore.drv
EOF
  refute_stderr
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"-v\",\"$tree/src:/src:ro\",\"$NIX_IMAGE\",\"nix\",\"path-info\",\"--derivation\",\"path:/src?dir=nixos#checks.x86_64-linux.atc-daemon\",\"path:/src?dir=nixos#checks.x86_64-linux.impd-restore\"]"
}

@test "it replaces an earlier calls copy of the source for a path info" {
  setup_test "$tree"
  mkdir -p "$tree/src/nixos" "$tree/saw/stale"
  echo '{ }' > "$tree/src/nixos/flake.nix"
  echo 'from an earlier call' > "$tree/saw/stale/file"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_SOURCE_SAW="$tree/saw" \
    docker run --rm -v "$tree/src:/src:ro" "$NIX_IMAGE" nix path-info --derivation 'path:/src?dir=nixos#checks.x86_64-linux.atc-daemon'

  diff -r "$tree/src" "$tree/saw"
  assert_output '/nix/store/00000000000000000000000000000000-atc-daemon.drv'
  refute_stderr
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"-v\",\"$tree/src:/src:ro\",\"$NIX_IMAGE\",\"nix\",\"path-info\",\"--derivation\",\"path:/src?dir=nixos#checks.x86_64-linux.atc-daemon\"]"
}

@test "it copies the source then fails a path info with the set error and exit 1" {
  setup_test "$tree"
  mkdir -p "$tree/src/nixos"
  echo '{ }' > "$tree/src/nixos/flake.nix"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_SOURCE_SAW="$tree/saw" \
    STUB_DERIVATION_ERROR="error: attribute 'atc-daemon' missing" \
    docker run --rm -v "$tree/src:/src:ro" "$NIX_IMAGE" nix path-info --derivation 'path:/src?dir=nixos#checks.x86_64-linux.atc-daemon'

  diff -r "$tree/src" "$tree/saw"
  refute_output
  assert_stderr "error: attribute 'atc-daemon' missing"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"-v\",\"$tree/src:/src:ro\",\"$NIX_IMAGE\",\"nix\",\"path-info\",\"--derivation\",\"path:/src?dir=nixos#checks.x86_64-linux.atc-daemon\"]"
}

@test "it prints nothing for a build" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    docker run --rm "$NIX_IMAGE" nix build --no-link -L '/nix/store/00000000000000000000000000000000-atc-daemon.drv^*'

  refute_output
  refute_stderr
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"$NIX_IMAGE\",\"nix\",\"build\",\"--no-link\",\"-L\",\"/nix/store/00000000000000000000000000000000-atc-daemon.drv^*\"]"
}

@test "it fails a build with the set error and exit 1" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_BUILD_ERROR="error: Cannot build 'x.drv'." \
    docker run --rm "$NIX_IMAGE" nix build --no-link -L '/nix/store/00000000000000000000000000000000-atc-daemon.drv^*'

  refute_output
  assert_stderr "error: Cannot build 'x.drv'."
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"$NIX_IMAGE\",\"nix\",\"build\",\"--no-link\",\"-L\",\"/nix/store/00000000000000000000000000000000-atc-daemon.drv^*\"]"
}

@test "it fails closed with exit 97 on any other call" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" docker volume rm cloud-nixos-checks-store

  refute_output
  assert_stderr "unexpected: volume rm cloud-nixos-checks-store"
  diff - "$tree/calls" <<< '["docker","volume","rm","cloud-nixos-checks-store"]'
}

# Runtime every case needs: the stand-in in <tree>/bin, and the HOME and TMPDIR each call
# runs with. The empty call log is boot data: the stand-in appends to it, and a case
# compares it whole.
@test "it prints the closure file for a closure query" {
  setup_test "$tree"
  printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern\n' > "$tree/closure"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CLOSURE="$tree/closure" \
    docker run --rm "$NIX_IMAGE" nix-store -qR --include-outputs /nix/store/00000000000000000000000000000000-lantern.drv > "$tree/out" 2> "$tree/err"

  diff "$tree/closure" "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"$NIX_IMAGE\",\"nix-store\",\"-qR\",\"--include-outputs\",\"/nix/store/00000000000000000000000000000000-lantern.drv\"]"
}

@test "it reads stdin and prints the path info file for a path info json" {
  setup_test "$tree"
  printf '{"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern":{"signatures":[]}}\n' > "$tree/path-info"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_PATH_INFO="$tree/path-info" \
    docker run --rm -i "$NIX_IMAGE" nix path-info --json --stdin \
    <<< /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern > "$tree/out" 2> "$tree/err"

  diff "$tree/path-info" "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"-i\",\"$NIX_IMAGE\",\"nix\",\"path-info\",\"--json\",\"--stdin\"]"
}

@test "it writes the cache info and a narinfo for each path for a copy to the cache" {
  setup_test "$tree"
  mkdir "$tree/cache"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    docker run --rm -i -v "$tree/cache:/cache" "$NIX_IMAGE" nix copy --no-recursive --stdin \
    --to 'file:///cache?compression=zstd' << 'EOF'
/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern
/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-wick
EOF

  refute_output
  refute_stderr
  diff - "$tree/cache/nix-cache-info" <<< 'StoreDir: /nix/store'
  diff - "$tree/cache/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.narinfo" <<< 'StorePath: /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern'
  diff - "$tree/cache/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.narinfo" <<< 'StorePath: /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-wick'
  ls -A "$tree/cache" > "$tree/cache-files"
  diff - "$tree/cache-files" << 'EOF'
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.narinfo
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.narinfo
nix-cache-info
EOF
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"-i\",\"-v\",\"$tree/cache:/cache\",\"$NIX_IMAGE\",\"nix\",\"copy\",\"--no-recursive\",\"--stdin\",\"--to\",\"file:///cache?compression=zstd\"]"
}

@test "it refuses a copy to the cache of a path whose reference the cache lacks" {
  setup_test "$tree"
  mkdir "$tree/cache"
  cat > "$tree/path-info" << 'EOF'
{"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern":{"references":["/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-wick","/nix/store/cccccccccccccccccccccccccccccccc-flint"]}}
EOF

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_PATH_INFO="$tree/path-info" \
    docker run --rm -i -v "$tree/cache:/cache" "$NIX_IMAGE" nix copy --no-recursive --stdin \
    --to 'file:///cache?compression=zstd' << 'EOF'
/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern
/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-wick
EOF

  refute_output
  assert_stderr "error: cannot add '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern' to the binary cache because the reference '/nix/store/cccccccccccccccccccccccccccccccc-flint' is not valid"
  ls -A "$tree/cache" > "$tree/cache-files"
  diff /dev/null "$tree/cache-files"
}

@test "it copies a path whose reference has a narinfo in the cache" {
  setup_test "$tree"
  mkdir "$tree/cache"
  printf 'StorePath: /nix/store/cccccccccccccccccccccccccccccccc-flint\n' > "$tree/cache/cccccccccccccccccccccccccccccccc.narinfo"
  cat > "$tree/path-info" << 'EOF'
{"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern":{"references":["/nix/store/cccccccccccccccccccccccccccccccc-flint"]}}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_PATH_INFO="$tree/path-info" \
    docker run --rm -i -v "$tree/cache:/cache" "$NIX_IMAGE" nix copy --no-recursive --stdin \
    --to 'file:///cache?compression=zstd' <<< '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern'

  refute_output
  refute_stderr
  diff - "$tree/cache/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.narinfo" <<< 'StorePath: /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern'
}
