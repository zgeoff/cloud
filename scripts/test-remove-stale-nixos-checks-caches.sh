#!/usr/bin/env bash
# Test for remove-stale-nixos-checks-caches.sh: against a gh stand-in
# (test-support/shell/create-stub-gh.sh) that replays the cache list each case records, as the
# lines its --jq filter prints ("<id> <key>" per cache), it deletes every listed cache but the kept
# one, deletes nothing when the kept one is alone, and fails with gh's error when the list fails.
# Each case runs the script under `env -i` and compares its whole stdout, stderr and gh call log.
#
#   bash scripts/test-remove-stale-nixos-checks-caches.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remove-stale-nixos-checks-caches.sh"

it_deletes_every_cache_of_main_but_the_kept_one() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh's manual (`gh cache list --help` and `gh cache delete --help`, gh 2.102.0, read 2026-10-28):
  # list filters by a key prefix and a ref, and delete takes a cache's id
  {
    jq -cn '{argv: ["gh", "cache", "list", "--key", "nixos-checks-store-main-", "--ref", "refs/heads/main",
      "--limit", "100", "--json", "id,key", "--jq", ".[] | \"\\(.id) \\(.key)\""],
      stdout: "31 nixos-checks-store-main-903\n17 nixos-checks-store-main-901\n12 nixos-checks-store-main-899\n"}'
    jq -cn '{argv: ["gh", "cache", "delete", "17"]}'
    jq -cn '{argv: ["gh", "cache", "delete", "12"]}'
  } > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" nixos-checks-store-main-903 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","cache","list","--key","nixos-checks-store-main-","--ref","refs/heads/main","--limit","100","--json","id,key","--jq",".[] | \"\\(.id) \\(.key)\""]
["gh","cache","delete","17"]
["gh","cache","delete","12"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 0 "$status"
}

it_deletes_nothing_when_the_kept_cache_is_alone() {
  local status=0
  create_case_tree
  setup_test "$tree"
  jq -cn '{argv: ["gh", "cache", "list", "--key", "nixos-checks-store-main-", "--ref", "refs/heads/main",
    "--limit", "100", "--json", "id,key", "--jq", ".[] | \"\\(.id) \\(.key)\""],
    stdout: "31 nixos-checks-store-main-903\n"}' > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" nixos-checks-store-main-903 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","cache","list","--key","nixos-checks-store-main-","--ref","refs/heads/main","--limit","100","--json","id,key","--jq",".[] | \"\\(.id) \\(.key)\""]
EOF
  assert_status 0 "$status"
}

it_fails_with_the_gh_error_when_the_list_fails() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed
  # command, such as an API error
  jq -cn '{argv: ["gh", "cache", "list", "--key", "nixos-checks-store-main-", "--ref", "refs/heads/main",
    "--limit", "100", "--json", "id,key", "--jq", ".[] | \"\\(.id) \\(.key)\""],
    stderr: "HTTP 503: Service Unavailable\n", exit: 1}' > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" nixos-checks-store-main-903 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'HTTP 503: Service Unavailable'
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 1 "$status"
}

it_fails_with_its_usage_without_a_kept_key() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: remove-stale-nixos-checks-caches.sh <kept cache key>'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

# setup_test <tree>: the gh stand-in in <tree>/bin, and the home and temp folders the script runs
# with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
}

run_cases
