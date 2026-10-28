#!/usr/bin/env bash
# Test for create-stub-checks-docker.sh: the docker stand-in answers the nix eval, path-info and
# build that run-nixos-checks.sh runs and the closure query, path-info and copy to a cache that
# write-nixos-checks-cache.sh runs, copies what the path-info call mounts at /src, logs every
# call, and fails closed on any other call. No nix runs here; the stand-in's exit 1 for a failed
# eval, path-info or build is the one its header records from one-off checks against nix 2.35.2.
#
#   bash test-support/shell/test-create-stub-checks-docker.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-checks-docker.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/nix-image.sh"

it_prints_the_check_names_without_a_trailing_newline_for_an_eval() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CHECKS=$'atc-daemon\nimpd-restore\n' \
    docker run --rm "$NIX_IMAGE" nix eval --raw 'path:/src?dir=nixos#checks.x86_64-linux' --apply builtins.attrNames \
    > "$tree/out" 2> "$tree/err" || status=$?

  printf 'atc-daemon\nimpd-restore\n' | cmp - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"$NIX_IMAGE\",\"nix\",\"eval\",\"--raw\",\"path:/src?dir=nixos#checks.x86_64-linux\",\"--apply\",\"builtins.attrNames\"]"
  assert_status 0 "$status"
}

it_fails_an_eval_with_the_set_error_and_exit_1() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CHECKS=atc-daemon \
    STUB_EVAL_ERROR="error: undefined variable 'x'" \
    docker run --rm "$NIX_IMAGE" nix eval --raw 'path:/src?dir=nixos#checks.x86_64-linux' --apply builtins.attrNames \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "error: undefined variable 'x'"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"$NIX_IMAGE\",\"nix\",\"eval\",\"--raw\",\"path:/src?dir=nixos#checks.x86_64-linux\",\"--apply\",\"builtins.attrNames\"]"
  assert_status 1 "$status"
}

it_copies_the_source_and_prints_each_checks_derivation_for_a_path_info() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/src/nixos"
  echo '{ }' > "$tree/src/nixos/flake.nix"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_SOURCE_SAW="$tree/saw" \
    docker run --rm -v "$tree/src:/src:ro" "$NIX_IMAGE" nix path-info --derivation \
    'path:/src?dir=nixos#checks.x86_64-linux.atc-daemon' 'path:/src?dir=nixos#checks.x86_64-linux.impd-restore' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff -r "$tree/src" "$tree/saw"
  diff - "$tree/out" << 'EOF'
/nix/store/00000000000000000000000000000000-atc-daemon.drv
/nix/store/00000000000000000000000000000000-impd-restore.drv
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"-v\",\"$tree/src:/src:ro\",\"$NIX_IMAGE\",\"nix\",\"path-info\",\"--derivation\",\"path:/src?dir=nixos#checks.x86_64-linux.atc-daemon\",\"path:/src?dir=nixos#checks.x86_64-linux.impd-restore\"]"
  assert_status 0 "$status"
}

it_replaces_an_earlier_calls_copy_of_the_source_for_a_path_info() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/src/nixos" "$tree/saw/stale"
  echo '{ }' > "$tree/src/nixos/flake.nix"
  echo 'from an earlier call' > "$tree/saw/stale/file"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_SOURCE_SAW="$tree/saw" \
    docker run --rm -v "$tree/src:/src:ro" "$NIX_IMAGE" nix path-info --derivation 'path:/src?dir=nixos#checks.x86_64-linux.atc-daemon' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff -r "$tree/src" "$tree/saw"
  diff - "$tree/out" <<< '/nix/store/00000000000000000000000000000000-atc-daemon.drv'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"-v\",\"$tree/src:/src:ro\",\"$NIX_IMAGE\",\"nix\",\"path-info\",\"--derivation\",\"path:/src?dir=nixos#checks.x86_64-linux.atc-daemon\"]"
  assert_status 0 "$status"
}

it_copies_the_source_then_fails_a_path_info_with_the_set_error_and_exit_1() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/src/nixos"
  echo '{ }' > "$tree/src/nixos/flake.nix"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_SOURCE_SAW="$tree/saw" \
    STUB_DERIVATION_ERROR="error: attribute 'atc-daemon' missing" \
    docker run --rm -v "$tree/src:/src:ro" "$NIX_IMAGE" nix path-info --derivation 'path:/src?dir=nixos#checks.x86_64-linux.atc-daemon' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff -r "$tree/src" "$tree/saw"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "error: attribute 'atc-daemon' missing"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"-v\",\"$tree/src:/src:ro\",\"$NIX_IMAGE\",\"nix\",\"path-info\",\"--derivation\",\"path:/src?dir=nixos#checks.x86_64-linux.atc-daemon\"]"
  assert_status 1 "$status"
}

it_prints_nothing_for_a_build() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    docker run --rm "$NIX_IMAGE" nix build --no-link -L '/nix/store/00000000000000000000000000000000-atc-daemon.drv^*' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"$NIX_IMAGE\",\"nix\",\"build\",\"--no-link\",\"-L\",\"/nix/store/00000000000000000000000000000000-atc-daemon.drv^*\"]"
  assert_status 0 "$status"
}

it_fails_a_build_with_the_set_error_and_exit_1() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_BUILD_ERROR="error: Cannot build 'x.drv'." \
    docker run --rm "$NIX_IMAGE" nix build --no-link -L '/nix/store/00000000000000000000000000000000-atc-daemon.drv^*' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "error: Cannot build 'x.drv'."
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"$NIX_IMAGE\",\"nix\",\"build\",\"--no-link\",\"-L\",\"/nix/store/00000000000000000000000000000000-atc-daemon.drv^*\"]"
  assert_status 1 "$status"
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" docker volume rm cloud-nixos-checks-store \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: volume rm cloud-nixos-checks-store"
  diff - "$tree/calls" <<< '["docker","volume","rm","cloud-nixos-checks-store"]'
  assert_status 97 "$status"
}

# Runtime every case needs: the stand-in in <tree>/bin, and the HOME and TMPDIR each call
# runs with. The empty call log is boot data: the stand-in appends to it, and a case
# compares it whole.
it_prints_the_closure_file_for_a_closure_query() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern\n' > "$tree/closure"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CLOSURE="$tree/closure" \
    docker run --rm "$NIX_IMAGE" nix-store -qR --include-outputs /nix/store/00000000000000000000000000000000-lantern.drv \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/closure" "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"$NIX_IMAGE\",\"nix-store\",\"-qR\",\"--include-outputs\",\"/nix/store/00000000000000000000000000000000-lantern.drv\"]"
  assert_status 0 "$status"
}

it_reads_stdin_and_prints_the_path_info_file_for_a_path_info_json() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '{"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern":{"signatures":[]}}\n' > "$tree/path-info"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_PATH_INFO="$tree/path-info" \
    docker run --rm -i "$NIX_IMAGE" nix path-info --json --stdin \
    <<< /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/path-info" "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"docker\",\"run\",\"--rm\",\"-i\",\"$NIX_IMAGE\",\"nix\",\"path-info\",\"--json\",\"--stdin\"]"
  assert_status 0 "$status"
}

it_writes_the_cache_info_and_a_narinfo_for_each_path_for_a_copy_to_the_cache() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir "$tree/cache"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    docker run --rm -i -v "$tree/cache:/cache" "$NIX_IMAGE" nix copy --no-recursive --stdin \
    --to 'file:///cache?compression=zstd' > "$tree/out" 2> "$tree/err" << 'EOF' || status=$?
/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-lantern
/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-wick
EOF

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
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
  assert_status 0 "$status"
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_checks_docker "$tree/bin"
}

run_cases
