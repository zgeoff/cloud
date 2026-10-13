#!/usr/bin/env bash
# Test for set-release-bot-identity.sh: in a real git repository in the case tree, with a gh
# stand-in (scripts/test-lib/create-stub-bot-user-gh.sh) that knows the bot users, it sets
# user.name to the app's bot login and user.email to the bot's noreply address with its id; a bot
# user GitHub does not know fails it with gh's error and leaves the identity unset; and a missing
# slug is a usage error. Each case runs the script under `env -i` with git's global and system
# config off, and compares its whole stdout, stderr, gh call log and the repository's config.
#
#   bash scripts/test-set-release-bot-identity.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-bot-user-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/set-release-bot-identity.sh"

it_sets_the_bot_user_name_and_noreply_address_with_its_id() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 41898282 > "$tree/users/cloud-release-check[bot]"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_TREE="$tree" \
    bash "$script" cloud-release-check) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","users/cloud-release-check%5Bbot%5D","--jq",".id"]'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/repo" config --local --get-regexp '^user\.' > "$tree/identity"
  diff - "$tree/identity" << 'EOF'
user.name cloud-release-check[bot]
user.email 41898282+cloud-release-check[bot]@users.noreply.github.com
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_with_the_gh_error_and_sets_nothing_for_a_bot_user_github_does_not_know() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_TREE="$tree" \
    bash "$script" no-such-app) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'gh: Not Found (HTTP 404)'
  diff - "$tree/calls" <<< '["gh","api","users/no-such-app%5Bbot%5D","--jq",".id"]'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/repo" config --local --get-regexp '^user\.' > "$tree/identity" || true
  diff /dev/null "$tree/identity"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_prints_its_usage_without_a_slug() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_TREE="$tree" \
    bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: set-release-bot-identity.sh <app slug>'
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

# setup_test <tree>: the gh stand-in in <tree>/bin, the home and temp folders the script runs
# with, <tree>/users for the bot users a case states, and <tree>/repo, an empty repository.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/users" "$tree/repo"
  : > "$tree/calls"
  create_stub_bot_user_gh "$tree/bin"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$tree/repo" init -q -b main
}

run_cases
