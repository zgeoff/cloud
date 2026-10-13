#!/usr/bin/env bash
# Test for lint.sh: in a real git repository in the case tree, it lints each kind of file git
# lists (tracked, or untracked and not ignored), leaving out .claude/, ignored files and deleted
# ones; it finds an extensionless sh or bash script by its shebang; it runs every tool of the kind
# in the pinned Nix image with the repo mounted read-only, and exits 1 when any tool failed after
# running them all; it fails when there is no file of the kind, and on an unknown kind. docker is a
# stand-in (create-stub-lint-docker.sh) that logs its argv, so no container runs. Each case runs a
# copy of the script under `env -i`, with git's global and system config off.
#
#   bash scripts/test-lint.sh
#   CASE='shell' bash scripts/test-lint.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-lint-docker.sh"
source "$(dirname "${BASH_SOURCE[0]}")/nix-image.sh"

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

it_lints_every_shell_file_git_lists_with_shellcheck_and_shfmt() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/images/sbin" "$tree/repo/ignored" "$tree/repo/.claude/hooks"
  echo '/ignored/' > "$tree/repo/.gitignore"
  printf '#!/usr/bin/env bash\ntrue\n' > "$tree/repo/scripts/b.sh"
  printf '#!/bin/sh\ntrue\n' > "$tree/repo/images/sbin/setup"
  printf '#!/usr/bin/env python3\nprint()\n' > "$tree/repo/images/sbin/tool"
  printf 'plain text\n' > "$tree/repo/images/README"
  printf '#!/usr/bin/env bash\ntrue\n' > "$tree/repo/ignored/c.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$tree/repo/.claude/hooks/d.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$tree/repo/gone.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add gone.sh scripts/b.sh
  rm "$tree/repo/gone.sh"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" bash scripts/lint.sh sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#shellcheck","-c","shellcheck","-x","images/sbin/setup","scripts/b.sh","scripts/lint.sh","scripts/nix-image.sh"]
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#shfmt","-c","shfmt","-d","images/sbin/setup","scripts/b.sh","scripts/lint.sh","scripts/nix-image.sh"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_lints_the_nix_files_under_nixos_with_nixfmt_and_deadnix() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/nixos/checks" "$tree/repo/other"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  echo '{ }' > "$tree/repo/nixos/checks/a.nix"
  echo '{ }' > "$tree/repo/other/b.nix"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" bash scripts/lint.sh nix) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#nixfmt","-c","nixfmt","--check","nixos/checks/a.nix","nixos/flake.nix"]
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#deadnix","-c","deadnix","--fail","nixos/checks/a.nix","nixos/flake.nix"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_lints_the_python_files_with_ruff_check_and_ruff_format() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/nixos/checks"
  echo 'print()' > "$tree/repo/nixos/checks/run-stub.py"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" bash scripts/lint.sh py) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#ruff","-c","ruff","check","--no-cache","nixos/checks/run-stub.py"]
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#ruff","-c","ruff","format","--check","--no-cache","nixos/checks/run-stub.py"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_lints_the_workflows_with_actionlint_in_the_store_volume_the_environment_names() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/.github/workflows"
  echo 'name: CI' > "$tree/repo/.github/workflows/ci.yml"
  echo 'name: other' > "$tree/repo/.github/workflows/other.yaml"
  echo 'name: not a workflow' > "$tree/repo/.github/dependabot.yml"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" LINT_STORE_VOLUME=ci-lint-store bash scripts/lint.sh actions) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
["docker","run","--rm","-v","ci-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#actionlint","-c","actionlint",".github/workflows/ci.yml",".github/workflows/other.yaml"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_runs_every_tool_of_the_kind_then_exits_1_when_one_failed() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/nixos"
  echo '{ }' > "$tree/repo/nixos/flake.nix"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" STUB_FAILING_TOOLS=nixfmt bash scripts/lint.sh nix) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'nixfmt: findings'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#nixfmt","-c","nixfmt","--check","nixos/flake.nix"]
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#deadnix","-c","deadnix","--fail","nixos/flake.nix"]
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_when_there_is_no_file_of_the_kind() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" bash scripts/lint.sh py) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'lint.sh: no py files to lint'
  [ ! -e "$tree/calls" ] || {
    echo "docker ran: $(cat "$tree/calls")" >&2
    exit 1
  }
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_rejects_an_unknown_kind_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" bash scripts/lint.sh go) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: lint.sh sh|nix|py|actions'
  [ ! -e "$tree/calls" ] || {
    echo "docker ran: $(cat "$tree/calls")" >&2
    exit 1
  }
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_rejects_a_call_without_a_kind_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" bash scripts/lint.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: lint.sh sh|nix|py|actions'
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

# a git repository whose scripts/ holds copies of lint.sh and the image pin it sources, tracked,
# so the script lints the case's repo and never the real one; docker is the lint stand-in
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo/scripts"
  create_stub_lint_docker "$tree/bin"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" init -q -b main
  cp "$scripts/lint.sh" "$scripts/nix-image.sh" "$tree/repo/scripts/"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add scripts
}

run_cases
