#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-lint-docker.sh: the docker stand-in exits 0 for each lint tool lint.sh runs,
# fails a tool that STUB_FAILING_TOOLS names with its findings and exit 1, logs every call, and
# fails closed on any other call. No container runs here; the exit 1 on findings is the one its
# header records from the pinned tools.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-lint-docker.sh'
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
  create_stub_lint_docker "$tree/bin"
}

@test "it exits 0 with no output for a tool that finds nothing" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_FAILING_TOOLS='ruff' \
    docker run --rm example/image nix shell nixpkgs#shfmt -c shfmt -d a.sh

  refute_output
  refute_stderr
  diff - "$tree/calls" <<< '["docker","run","--rm","example/image","nix","shell","nixpkgs#shfmt","-c","shfmt","-d","a.sh"]'
}

@test "it fails a named tool with its findings and exit 1" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_FAILING_TOOLS='shfmt deadnix' \
    docker run --rm example/image nix shell nixpkgs#deadnix -c deadnix --fail a.nix

  assert_output 'deadnix: findings'
  refute_stderr
  diff - "$tree/calls" <<< '["docker","run","--rm","example/image","nix","shell","nixpkgs#deadnix","-c","deadnix","--fail","a.nix"]'
}

@test "it answers each tool lint sh runs" {
  setup_test "$tree"

  for tool in shellcheck shfmt nixfmt deadnix ruff actionlint; do
    run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_FAILING_TOOLS="$tool" \
      docker run --rm example/image nix shell "nixpkgs#$tool" -c "$tool"
    assert_output "$tool: findings"
    refute_stderr
  done
}

@test "it fails closed with exit 97 on a tool it does not model" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    docker run --rm example/image nix shell nixpkgs#hello -c hello

  refute_output
  assert_stderr 'unexpected: run --rm example/image nix shell nixpkgs#hello -c hello'
  diff - "$tree/calls" <<< '["docker","run","--rm","example/image","nix","shell","nixpkgs#hello","-c","hello"]'
}

@test "it fails closed with exit 97 on any other docker call" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    docker volume rm cloud-lint-store

  refute_output
  assert_stderr 'unexpected: volume rm cloud-lint-store'
  diff - "$tree/calls" <<< '["docker","volume","rm","cloud-lint-store"]'
}
