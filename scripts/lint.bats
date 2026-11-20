#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for lint.sh: in a real git repository in the case tree, it lints each kind of file git
# lists (tracked, or untracked and not ignored), leaving out .claude/, ignored files and deleted
# ones; it finds an extensionless sh or bash script by its shebang; it runs every tool of the kind
# in the pinned Nix image with the repo mounted read-only, and exits 1 when any tool failed after
# running them all; it fails when there is no file of the kind, and on an unknown kind. docker is a
# stand-in (create-stub-lint-docker.sh) that logs its argv, so no container runs. Each case runs a
# copy of the script under `env -i`, with git's global and system config off.
#
#   bash scripts/run-bats.sh
#   CASE='shell' bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-lint-docker.sh'
  load 'nix-image.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  scripts="$BATS_TEST_DIRNAME"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
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

@test "it lints every shell file git lists with shellcheck and shfmt" {
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

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" bash scripts/lint.sh sh

  refute_output
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#shellcheck","-c","shellcheck","-x","images/sbin/setup","scripts/b.sh","scripts/lint.sh","scripts/nix-image.sh"]
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#shfmt","-c","shfmt","-d","images/sbin/setup","scripts/b.sh","scripts/lint.sh","scripts/nix-image.sh"]
EOF
}

@test "it lints the nix files under nixos with nixfmt and deadnix" {
  setup_test "$tree"
  mkdir -p "$tree/repo/nixos/checks" "$tree/repo/other"
  echo '{ }' > "$tree/repo/nixos/flake.nix"
  echo '{ }' > "$tree/repo/nixos/checks/a.nix"
  echo '{ }' > "$tree/repo/other/b.nix"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" bash scripts/lint.sh nix

  refute_output
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#nixfmt","-c","nixfmt","--check","nixos/checks/a.nix","nixos/flake.nix"]
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#deadnix","-c","deadnix","--fail","nixos/checks/a.nix","nixos/flake.nix"]
EOF
}

@test "it lints the python files with ruff check and ruff format" {
  setup_test "$tree"
  mkdir -p "$tree/repo/nixos/checks"
  echo 'print()' > "$tree/repo/nixos/checks/run-stub.py"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" bash scripts/lint.sh py

  refute_output
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#ruff","-c","ruff","check","--no-cache","nixos/checks/run-stub.py"]
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#ruff","-c","ruff","format","--check","--no-cache","nixos/checks/run-stub.py"]
EOF
}

@test "it lints the workflows with actionlint in the store volume the environment names" {
  setup_test "$tree"
  mkdir -p "$tree/repo/.github/workflows"
  echo 'name: CI' > "$tree/repo/.github/workflows/ci.yml"
  echo 'name: other' > "$tree/repo/.github/workflows/other.yaml"
  echo 'name: not a workflow' > "$tree/repo/.github/dependabot.yml"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" LINT_STORE_VOLUME=ci-lint-store bash scripts/lint.sh actions

  refute_output
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
["docker","run","--rm","-v","ci-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#actionlint","-c","actionlint",".github/workflows/ci.yml",".github/workflows/other.yaml"]
EOF
}

@test "it runs every tool of the kind then exits 1 when one failed" {
  setup_test "$tree"
  mkdir -p "$tree/repo/nixos"
  echo '{ }' > "$tree/repo/nixos/flake.nix"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" STUB_FAILING_TOOLS=nixfmt bash scripts/lint.sh nix

  assert_output 'nixfmt: findings'
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#nixfmt","-c","nixfmt","--check","nixos/flake.nix"]
["docker","run","--rm","-v","cloud-lint-store:/nix","-v","$tree/repo:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","--inputs-from","path:/src/nixos","nixpkgs#deadnix","-c","deadnix","--fail","nixos/flake.nix"]
EOF
}

@test "it fails when there is no file of the kind" {
  setup_test "$tree"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" bash scripts/lint.sh py

  refute_output
  assert_stderr 'lint.sh: no py files to lint'

  refute [ -e "$tree/calls" ]
}

@test "it rejects an unknown kind with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" bash scripts/lint.sh go

  refute_output
  assert_stderr 'usage: lint.sh sh|nix|py|actions'

  refute [ -e "$tree/calls" ]
}

@test "it rejects a call without a kind with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" bash scripts/lint.sh

  refute_output
  assert_stderr 'usage: lint.sh sh|nix|py|actions'
}
