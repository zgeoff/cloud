#!/usr/bin/env bash
# Test for open-atc-pin-pr.sh: from a clone of a real bare repository in the case tree, it pins a
# release on the atc-pin/agent-image branch from origin's main, force-pushes that branch, and opens
# a pull request, or updates the open one after it turns that one's auto-merge off. It stops with
# no push and no gh call when main already pins the release, when the branch already holds a
# newer release, and when the pin fails. gh is the create-stub-pin-pr-gh.sh stand-in; git is
# real, under `env -i` with git's global and system config off.
#
#   bash scripts/test-open-atc-pin-pr.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/test-lib/run-cases.sh"
source "$scripts/test-lib/create-stub-pin-pr-gh.sh"

script="$scripts/open-atc-pin-pr.sh"

# setup_test <tree>: a bare repository at <tree>/origin.git, a working repository at <tree>/seed
# whose origin it is, holding scripts/pin-agent-atc.sh, which the script under test runs from its
# checkout, the gh stand-in in <tree>/bin, and the home and temp folders the cases run with. It
# sets case_env, the environment every git and script call in a case runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/seed/scripts"
  create_stub_pin_pr_gh "$tree/bin"
  case_env=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp"
    STUB_TREE="$tree" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid)
  "${case_env[@]}" git init -q --bare -b main "$tree/origin.git"
  "${case_env[@]}" git -C "$tree/seed" init -q -b main
  "${case_env[@]}" git -C "$tree/seed" remote add origin "$tree/origin.git"
  cp "$scripts/pin-agent-atc.sh" "$tree/seed/scripts/pin-agent-atc.sh"
}

it_opens_a_pin_pull_request_when_none_is_open() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" 3.11.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
pinned atc 3.11.0: 4444444444444444444444444444444444444444444444444444444444444444
https://github.com/zgeoff/cloud/pull/200
EOF
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" show atc-pin/agent-image:images/agent/Dockerfile) << 'EOF'
ARG ATC_VERSION=3.11.0
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
EOF
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" log --format=%s main..atc-pin/agent-image) <<< 'chore: pin atc 3.11.0 in the agent image'
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","atc-pin/agent-image","--state","open","--json","number,autoMergeRequest"]
["gh","pr","create","--repo","zgeoff/cloud","--base","main","--head","atc-pin/agent-image","--title","chore: pin atc 3.11.0 in the agent image","--body","Pins atc 3.11.0 in the agent image, with the atc-linux-x64 sum from the release's SHA256SUMS. The agent image workflow turns on auto-merge once the image builds and passes its check and the diff changes only the two atc pins. After the merge, build and check the image as docs/runbooks/agent-image.md describes."]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_updates_the_open_pull_request_after_it_turns_auto_merge_off() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc atc-pin/agent-image
  sed -i -e 's/^ARG ATC_VERSION=.*/ARG ATC_VERSION=3.10.9/' \
    -e 's/^ARG ATC_SHA256=.*/ARG ATC_SHA256=5555555555555555555555555555555555555555555555555555555555555555/' \
    "$tree/seed/images/agent/Dockerfile"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore: pin atc 3.10.9 in the agent image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin atc-pin/agent-image
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo '[{"autoMergeRequest":{"mergeMethod":"SQUASH"},"number":12}]' > "$tree/open-prs"
  echo '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" 3.11.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
pinned atc 3.11.0: 4444444444444444444444444444444444444444444444444444444444444444
https://github.com/zgeoff/cloud/pull/12
EOF
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" show atc-pin/agent-image:images/agent/Dockerfile) << 'EOF'
ARG ATC_VERSION=3.11.0
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
EOF
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" log --format=%s main..atc-pin/agent-image) <<< 'chore: pin atc 3.11.0 in the agent image'
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","atc-pin/agent-image","--state","open","--json","number,autoMergeRequest"]
["gh","pr","merge","12","--repo","zgeoff/cloud","--disable-auto"]
["gh","pr","edit","12","--repo","zgeoff/cloud","--title","chore: pin atc 3.11.0 in the agent image","--body","Pins atc 3.11.0 in the agent image, with the atc-linux-x64 sum from the release's SHA256SUMS. The agent image workflow turns on auto-merge once the image builds and passes its check and the diff changes only the two atc pins. After the merge, build and check the image as docs/runbooks/agent-image.md describes."]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_updates_an_open_pull_request_without_auto_merge_directly() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo '[{"autoMergeRequest":null,"number":12}]' > "$tree/open-prs"
  echo '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" 3.11.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
pinned atc 3.11.0: 4444444444444444444444444444444444444444444444444444444444444444
https://github.com/zgeoff/cloud/pull/12
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","atc-pin/agent-image","--state","open","--json","number,autoMergeRequest"]
["gh","pr","edit","12","--repo","zgeoff/cloud","--title","chore: pin atc 3.11.0 in the agent image","--body","Pins atc 3.11.0 in the agent image, with the atc-linux-x64 sum from the release's SHA256SUMS. The agent image workflow turns on auto-merge once the image builds and passes its check and the diff changes only the two atc pins. After the merge, build and check the image as docs/runbooks/agent-image.md describes."]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_stops_when_main_already_pins_the_release() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.11.0
ARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444
EOF
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" 3.11.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'atc 3.11.0 is already pinned'
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" for-each-ref --format='%(refname)') <<< 'refs/heads/main'
  [ ! -e "$tree/calls" ] || { echo "gh ran: $(cat "$tree/calls")" >&2; exit 1; }
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_stops_when_the_branch_already_holds_a_newer_release() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc atc-pin/agent-image
  sed -i -e 's/^ARG ATC_VERSION=.*/ARG ATC_VERSION=3.11.1/' \
    -e 's/^ARG ATC_SHA256=.*/ARG ATC_SHA256=5555555555555555555555555555555555555555555555555555555555555555/' \
    "$tree/seed/images/agent/Dockerfile"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore: pin atc 3.11.1 in the agent image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin atc-pin/agent-image
  "${case_env[@]}" git --git-dir="$tree/origin.git" rev-parse atc-pin/agent-image > "$tree/before"
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64' > "$tree/SHA256SUMS"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" 3.11.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'atc-pin/agent-image already pins atc 3.11.1, which is not older than 3.11.0'
  diff /dev/null "$tree/err"
  diff "$tree/before" <("${case_env[@]}" git --git-dir="$tree/origin.git" rev-parse atc-pin/agent-image)
  [ ! -e "$tree/calls" ] || { echo "gh ran: $(cat "$tree/calls")" >&2; exit 1; }
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_without_a_push_when_the_pin_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=3.10.2
ARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4
EOF
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo '3333333333333333333333333333333333333333333333333333333333333333  atc-linux-arm64' > "$tree/SHA256SUMS"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" 3.11.0 "$tree/SHA256SUMS") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'SHA256SUMS has 0 atc-linux-x64 lines, want 1'
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" for-each-ref --format='%(refname)') <<< 'refs/heads/main'
  [ ! -e "$tree/calls" ] || { echo "gh ran: $(cat "$tree/calls")" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_prints_its_usage_without_a_sha256sums_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script" 3.11.0) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: open-atc-pin-pr.sh <version> <SHA256SUMS file>'
  [ ! -e "$tree/calls" ] || { echo "gh ran: $(cat "$tree/calls")" >&2; exit 1; }
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

run_cases
