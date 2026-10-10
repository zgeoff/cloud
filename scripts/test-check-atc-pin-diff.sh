#!/usr/bin/env bash
# Test for check-atc-pin-diff.sh: against a real git repository in the case tree, it accepts a
# change from the merge base that sets both atc pins in images/agent/Dockerfile and nothing else,
# and refuses a change to another file, to another Dockerfile line, to one pin only, to a file's
# mode, and an empty change. Each case runs the script under `env -i` with git's global and
# system config off.
#
#   bash scripts/test-check-atc-pin-diff.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-atc-pin-diff.sh"

# setup_test <tree>: an empty git repository at <tree>/repo on branch main, with an identity for
# its commits, and the home and temp folders the cases run with
setup_test() {
  local tree="$1"
  mkdir -p "$tree/repo" "$tree/home" "$tree/tmp"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" init -q -b main
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" config user.name test
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" config user.email test@example.invalid
}

it_accepts_a_change_to_both_atc_pins_only() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/images/agent"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:0.33.0
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
ARG CODEX_VERSION=0.160.1
EOF
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the image'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -qc pin
  sed -i -e 's/^ARG ATC_VERSION=.*/ARG ATC_VERSION=3.11.0/' \
    -e 's/^ARG ATC_SHA256=.*/ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444/' \
    "$tree/repo/images/agent/Dockerfile"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'pin atc 3.11.0'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" main pin) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'the diff changes only the atc pins in images/agent/Dockerfile'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_compares_from_the_merge_base_when_main_moved_on() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/images/agent"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the image'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -qc pin
  sed -i -e 's/^ARG ATC_VERSION=.*/ARG ATC_VERSION=3.11.0/' \
    -e 's/^ARG ATC_SHA256=.*/ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444/' \
    "$tree/repo/images/agent/Dockerfile"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'pin atc 3.11.0'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -q main
  echo '# readme' > "$tree/repo/README.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a readme'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" main pin) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'the diff changes only the atc pins in images/agent/Dockerfile'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_refuses_a_change_to_another_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/images/agent" "$tree/repo/scripts"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  echo 'echo check' > "$tree/repo/scripts/check-agent-image.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the image'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -qc pin
  sed -i -e 's/^ARG ATC_VERSION=.*/ARG ATC_VERSION=3.11.0/' \
    -e 's/^ARG ATC_SHA256=.*/ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444/' \
    "$tree/repo/images/agent/Dockerfile"
  echo 'exit 0' > "$tree/repo/scripts/check-agent-image.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'pin atc 3.11.0'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" main pin) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the diff changes scripts/check-agent-image.sh, not only images/agent/Dockerfile'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_change_to_another_dockerfile_line() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/images/agent"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
ARG CODEX_VERSION=0.160.1
EOF
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the image'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -qc pin
  sed -i -e 's/^ARG ATC_VERSION=.*/ARG ATC_VERSION=3.11.0/' \
    -e 's/^ARG ATC_SHA256=.*/ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444/' \
    -e 's/^ARG CODEX_VERSION=.*/ARG CODEX_VERSION=0.161.0/' \
    "$tree/repo/images/agent/Dockerfile"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'pin atc 3.11.0'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" main pin) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the diff changes a Dockerfile line other than the atc pins: -ARG CODEX_VERSION=0.160.1'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_change_to_the_version_pin_alone() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/images/agent"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the image'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -qc pin
  sed -i -e 's/^ARG ATC_VERSION=.*/ARG ATC_VERSION=3.11.0/' "$tree/repo/images/agent/Dockerfile"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'pin atc 3.11.0'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" main pin) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the diff must replace each atc pin once; it removes 1 and adds 1 ATC_VERSION lines, and removes 0 and adds 0 ATC_SHA256 lines'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_change_to_the_dockerfile_mode() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/images/agent"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the image'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -qc pin
  sed -i -e 's/^ARG ATC_VERSION=.*/ARG ATC_VERSION=3.11.0/' \
    -e 's/^ARG ATC_SHA256=.*/ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444/' \
    "$tree/repo/images/agent/Dockerfile"
  chmod 0755 "$tree/repo/images/agent/Dockerfile"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'pin atc 3.11.0'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" main pin) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the diff changes a file mode, or creates or removes a file: mode change 100644 => 100755 images/agent/Dockerfile'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_an_empty_change() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/images/agent"
  echo 'ARG ATC_VERSION=3.10.2' > "$tree/repo/images/agent/Dockerfile"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the image'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -qc pin

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" main pin) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the diff changes nothing'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_with_gits_error_on_a_base_git_cannot_resolve() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '# readme' > "$tree/repo/README.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a readme'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" nosuch main) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
fatal: ambiguous argument 'nosuch...main': unknown revision or path not in the working tree.
Use '--' to separate paths from revisions, like this:
'git <command> [<revision>...] -- [<file>...]'
EOF
  [ "$status" = 128 ] || { echo "exit $status, want 128" >&2; exit 1; }
}

it_prints_its_usage_without_two_commits() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" main) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: check-atc-pin-diff.sh <base> <head>'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

run_cases
