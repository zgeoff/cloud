#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for remove-stale-nixos-checks-caches.sh: against a gh stand-in
# (scripts/src/test-utils/shell/create-stub-gh.sh) that replays the cache list each case records, as the
# lines its --jq filter prints ("<id> <key>" per cache), it deletes every cache an earlier run
# saved, keeps one a later run saved, deletes nothing when the kept one is alone, names a cache it
# could not delete and goes on, and fails with gh's error when the list fails.
# Each case runs the script under `env -i` and compares its whole stdout, stderr and gh call log.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-gh.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/remove-stale-nixos-checks-caches.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# setup_test <tree>: the gh stand-in in <tree>/bin, and the home and temp folders the script runs
# with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
}

@test "it deletes every cache an earlier run saved" {
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

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" nixos-checks-store-main-903

  refute_output
  refute_stderr

  run -0 diff - "$tree/calls" << 'EOF'
["gh","cache","list","--key","nixos-checks-store-main-","--ref","refs/heads/main","--limit","100","--json","id,key","--jq",".[] | \"\\(.id) \\(.key)\""]
["gh","cache","delete","17"]
["gh","cache","delete","12"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it deletes nothing when the kept cache is alone" {
  setup_test "$tree"
  jq -cn '{argv: ["gh", "cache", "list", "--key", "nixos-checks-store-main-", "--ref", "refs/heads/main",
    "--limit", "100", "--json", "id,key", "--jq", ".[] | \"\\(.id) \\(.key)\""],
    stdout: "31 nixos-checks-store-main-903\n"}' > "$tree/gh-responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" nixos-checks-store-main-903

  refute_output
  refute_stderr

  run -0 diff - "$tree/calls" << 'EOF'
["gh","cache","list","--key","nixos-checks-store-main-","--ref","refs/heads/main","--limit","100","--json","id,key","--jq",".[] | \"\\(.id) \\(.key)\""]
EOF
}

@test "it keeps a cache that a later run saved" {
  setup_test "$tree"
  {
    jq -cn '{argv: ["gh", "cache", "list", "--key", "nixos-checks-store-main-", "--ref", "refs/heads/main",
      "--limit", "100", "--json", "id,key", "--jq", ".[] | \"\\(.id) \\(.key)\""],
      stdout: "40 nixos-checks-store-main-907\n31 nixos-checks-store-main-903\n17 nixos-checks-store-main-901\n"}'
    jq -cn '{argv: ["gh", "cache", "delete", "17"]}'
  } > "$tree/gh-responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" nixos-checks-store-main-903

  refute_output
  refute_stderr

  run -0 diff - "$tree/calls" << 'EOF'
["gh","cache","list","--key","nixos-checks-store-main-","--ref","refs/heads/main","--limit","100","--json","id,key","--jq",".[] | \"\\(.id) \\(.key)\""]
["gh","cache","delete","17"]
EOF
}

@test "it names a cache it could not delete and goes on" {
  setup_test "$tree"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed
  # command, such as a delete of a cache another run already removed
  {
    jq -cn '{argv: ["gh", "cache", "list", "--key", "nixos-checks-store-main-", "--ref", "refs/heads/main",
      "--limit", "100", "--json", "id,key", "--jq", ".[] | \"\\(.id) \\(.key)\""],
      stdout: "31 nixos-checks-store-main-903\n17 nixos-checks-store-main-901\n12 nixos-checks-store-main-899\n"}'
    jq -cn '{argv: ["gh", "cache", "delete", "17"], stderr: "HTTP 404: Not Found\n", exit: 1}'
    jq -cn '{argv: ["gh", "cache", "delete", "12"]}'
  } > "$tree/gh-responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" nixos-checks-store-main-903

  refute_output
  assert_stderr - << 'EOF'
HTTP 404: Not Found
remove-stale-nixos-checks-caches: left nixos-checks-store-main-901
EOF

  run -0 diff - "$tree/calls" << 'EOF'
["gh","cache","list","--key","nixos-checks-store-main-","--ref","refs/heads/main","--limit","100","--json","id,key","--jq",".[] | \"\\(.id) \\(.key)\""]
["gh","cache","delete","17"]
["gh","cache","delete","12"]
EOF
}

@test "it fails with the gh error when the list fails" {
  setup_test "$tree"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed
  # command, such as an API error
  jq -cn '{argv: ["gh", "cache", "list", "--key", "nixos-checks-store-main-", "--ref", "refs/heads/main",
    "--limit", "100", "--json", "id,key", "--jq", ".[] | \"\\(.id) \\(.key)\""],
    stderr: "HTTP 503: Service Unavailable\n", exit: 1}' > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" nixos-checks-store-main-903

  refute_output
  assert_stderr 'HTTP 503: Service Unavailable'

  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it fails with its usage without a kept key" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script"

  refute_output
  assert_stderr 'usage: remove-stale-nixos-checks-caches.sh <kept cache key>'

  run -0 diff /dev/null "$tree/calls"
}
