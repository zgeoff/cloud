#!/usr/bin/env bash
# Lint one kind of file across the repo with tools from the nixpkgs that nixos/flake.lock pins,
# run in the pinned Nix image (scripts/nix-image.sh), so CI and lefthook run the same versions and
# you need no local install of any of them:
#
#   bash scripts/lint.sh sh        # shellcheck -x and shfmt -d (style from .editorconfig)
#   bash scripts/lint.sh nix       # nixfmt --check and deadnix --fail over nixos/
#   bash scripts/lint.sh py        # ruff check and ruff format --check over the .py files
#   bash scripts/lint.sh actions   # actionlint over .github/workflows/
#
# The files are the ones git tracks, or that are untracked and not ignored, so a new file is
# linted before it is committed; .claude/ is left out, because repo-sync owns those files. The
# shell files are every *.sh and every extensionless file whose first line is a sh or bash
# shebang. The repo mounts read-only at /src, so no tool can change a file. The Docker volume
# LINT_STORE_VOLUME (default cloud-lint-store) keeps the Nix store, and so the tools, between runs.
# It runs every tool of the kind, then exits 1 when any of them failed.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$here/nix-image.sh"
cd "$here/.."

if [ "$#" -ne 1 ]; then
  echo "usage: lint.sh sh|nix|py|actions" >&2
  exit 2
fi
kind="$1"

volume="${LINT_STORE_VOLUME:-cloud-lint-store}"

# the files git lists for the pathspecs, minus .claude/ and any listed file that is gone
list_files() {
  git ls-files -z --cached --others --exclude-standard --deduplicate -- "$@" |
    while IFS= read -r -d '' file; do
      case "$file" in
        .claude/*) continue ;;
      esac
      if [ -f "$file" ]; then
        printf '%s\n' "$file"
      fi
    done | LC_ALL=C sort
}

list_shell_files() {
  list_files ':(glob)**/*.sh'
  list_files . | grep -v '\.[^/]*$' | while IFS= read -r file; do
    if head -n 1 "$file" | grep -qE '^#!.*[/ ](ba)?sh$'; then
      printf '%s\n' "$file"
    fi
  done
}

# run_tool <package…> -- <command…>: runs the command with the nixpkgs packages on PATH
run_tool() {
  local packages=()
  while [ "$1" != -- ]; do
    packages+=("nixpkgs#$1")
    shift
  done
  shift
  docker run --rm -v "$volume:/nix" -v "$PWD:/src:ro" -w /src "$NIX_IMAGE" \
    nix --extra-experimental-features "nix-command flakes" shell --inputs-from path:/src/nixos \
    "${packages[@]}" -c "$@"
}

case "$kind" in
  sh) mapfile -t files < <(list_shell_files | LC_ALL=C sort) ;;
  nix) mapfile -t files < <(list_files ':(glob)nixos/**/*.nix') ;;
  py) mapfile -t files < <(list_files ':(glob)**/*.py') ;;
  actions) mapfile -t files < <(list_files ':(glob).github/workflows/*.yml' ':(glob).github/workflows/*.yaml') ;;
  *)
    echo "usage: lint.sh sh|nix|py|actions" >&2
    exit 2
    ;;
esac

if [ "${#files[@]}" -eq 0 ]; then
  echo "lint.sh: no $kind files to lint" >&2
  exit 1
fi

failed=0
case "$kind" in
  sh)
    run_tool shellcheck -- shellcheck -x "${files[@]}" || failed=1
    run_tool shfmt -- shfmt -d "${files[@]}" || failed=1
    ;;
  nix)
    run_tool nixfmt -- nixfmt --check "${files[@]}" || failed=1
    run_tool deadnix -- deadnix --fail "${files[@]}" || failed=1
    ;;
  py)
    run_tool ruff -- ruff check --no-cache "${files[@]}" || failed=1
    run_tool ruff -- ruff format --check --no-cache "${files[@]}" || failed=1
    ;;
  actions)
    run_tool actionlint -- actionlint "${files[@]}" || failed=1
    ;;
esac
exit "$failed"
