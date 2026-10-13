#!/usr/bin/env bash
# Test for create-stub-lint-docker.sh: the docker stand-in exits 0 for each lint tool lint.sh runs,
# fails a tool that STUB_FAILING_TOOLS names with its findings and exit 1, logs every call, and
# fails closed on any other call. No container runs here; the exit 1 on findings is the one its
# header records from the pinned tools.
#
#   bash scripts/test-lib/test-create-stub-lint-docker.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-lint-docker.sh"

it_exits_0_with_no_output_for_a_tool_that_finds_nothing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_FAILING_TOOLS='ruff' \
    docker run --rm example/image nix shell nixpkgs#shfmt -c shfmt -d a.sh > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["docker","run","--rm","example/image","nix","shell","nixpkgs#shfmt","-c","shfmt","-d","a.sh"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_a_named_tool_with_its_findings_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_FAILING_TOOLS='shfmt deadnix' \
    docker run --rm example/image nix shell nixpkgs#deadnix -c deadnix --fail a.nix > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'deadnix: findings'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["docker","run","--rm","example/image","nix","shell","nixpkgs#deadnix","-c","deadnix","--fail","a.nix"]'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_answers_each_tool_lint_sh_runs() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  for tool in shellcheck shfmt nixfmt deadnix ruff actionlint; do
    env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_FAILING_TOOLS="$tool" \
      docker run --rm example/image nix shell "nixpkgs#$tool" -c "$tool" >> "$tree/out" 2>> "$tree/err" || status=$((status + $?))
  done

  diff - "$tree/out" << 'EOF'
shellcheck: findings
shfmt: findings
nixfmt: findings
deadnix: findings
ruff: findings
actionlint: findings
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 6 ] || {
    echo "summed exit $status, want 6" >&2
    exit 1
  }
}

it_fails_closed_with_exit_97_on_a_tool_it_does_not_model() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    docker run --rm example/image nix shell nixpkgs#hello -c hello > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: run --rm example/image nix shell nixpkgs#hello -c hello'
  diff - "$tree/calls" <<< '["docker","run","--rm","example/image","nix","shell","nixpkgs#hello","-c","hello"]'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

it_fails_closed_with_exit_97_on_any_other_docker_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    docker volume rm cloud-lint-store > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: volume rm cloud-lint-store'
  diff - "$tree/calls" <<< '["docker","volume","rm","cloud-lint-store"]'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_lint_docker "$tree/bin"
}

run_cases
