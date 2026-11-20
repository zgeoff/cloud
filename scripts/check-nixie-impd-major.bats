#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for check-nixie-impd-major.sh: it passes an impd pin of the nixie imp client's major, from
# @zgeoff/imp-client or @impz/client, with @impz/client's version when the lock names both,
# nixie 0.28.0 or later on a 1.x client beside impd 2, and from nixie 0.42.0 an impd major in
# nixie's EXTRA_IMPD_MAJORS set, read from the adapter's sandbox folder from nixie 0.72.0. It refuses an impd major bump ahead of the client, an older nixie
# on a 1.x client beside impd 2, an impd major outside the set or before nixie 0.42.0, no nixie
# pod, an image that is no nixie release, a lock without the client, a failed lock or source read,
# and a configuration.nix without the imp-host pin. gh is the stand-in from scripts/src/test-utils/shell,
# which replays the answer each case records to the read of a nixie release's bun.lock and imp
# adapter source. Each case writes its own configuration.nix in the case tree and runs the script
# under `env -i`, and compares its stdout, stderr and gh call log.
#
# The recorded locks in scripts/src/test-utils/shell/gh-recordings hold `@zgeoff/imp-client` in the catalog
# and the packages, in the line forms bun 1.4 writes (nixie's bun.lock at v0.28.0, read
# 2026-10-16), or no such entry. The `impz-client` locks hold `@impz/client` in a workspace's
# dependencies, the catalog and the packages, in the line forms of lockfileVersion 2 (nixie's
# bun.lock at v0.37.0, read 2026-10-20, and at v0.42.0 for client 3.0.0, read 2026-10-24), and one
# of them holds an `@zgeoff/imp-client` beside it. The `build-imp-port` recordings hold the end of
# nixie's adapters/sandbox-imp/src/build-imp-port.ts, read 2026-10-24: its EXTRA_IMPD_MAJORS set of
# [2] at v0.42.0 and of [2, 4] at main, and no such set at v0.41.0.
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
  script="$BATS_TEST_DIRNAME/check-nixie-impd-major.sh"
  recordings="$(cd "$BATS_TEST_DIRNAME/../scripts/src/test-utils/shell/gh-recordings" && pwd)"
  digest=sha256:7f3e9c1a5b2d4e6f8a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# setup_test <tree>: the home and temp folders the cases run with, and the gh stand-in, which
# answers from <tree>/gh-responses
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
}

# write_config <tree> <imp-host version>: a configuration.nix that pins that imp-host release
write_config() {
  cat > "$1/configuration.nix" << EOF
  services.imp = {
    enable = true;
    image = "ghcr.io/zgeoff/imp-host:$2@$digest";
  };
EOF
}

lock_call() {
  printf '["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/bun.lock?ref=v%s"]\n' "$1"
}

@test "it passes a nixie whose imp client shares the impd major" {
  setup_test "$tree"
  write_config "$tree" 3.4.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-imp-client-3.2.1.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.31.4"],
    stdout_file: $lock}' > "$tree/gh-responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.31.4@$digest"

  assert_output '== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster'
  refute_stderr

  run -0 diff - "$tree/calls" <<< "$(lock_call 0.31.4)"
}

@test "it passes a nixie whose impz client shares the impd major" {
  setup_test "$tree"
  write_config "$tree" 2.1.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-impz-client-2.7.0.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.37.0"],
    stdout_file: $lock}' > "$tree/gh-responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.37.0@$digest"

  assert_output '== impd 2.1.0 on the host, nixie 0.37.0 (imp-client 2.7.0) in the cluster'
  refute_stderr

  run -0 diff - "$tree/calls" <<< "$(lock_call 0.37.0)"
}

@test "it refuses an impd major other than the impz client major" {
  setup_test "$tree"
  write_config "$tree" 3.0.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-impz-client-2.7.0.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.37.0"],
    stdout_file: $lock}' > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.37.0@$digest"

  refute_output
  assert_stderr 'the switch would run impd 3.0.0, but a nixie pod runs nixie 0.37.0 (imp-client 2.7.0), which accepts impd 2 only; deploy a nixie that speaks impd 3 first (docs/runbooks/workflows.md, Switch the host)'

  run -0 diff - "$tree/calls" <<< "$(lock_call 0.37.0)"
}

@test "it takes the impz client version from a lock that names both clients" {
  setup_test "$tree"
  write_config "$tree" 2.1.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-impz-client-2.7.0-and-imp-client-3.2.1.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.37.0"],
    stdout_file: $lock}' > "$tree/gh-responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.37.0@$digest"

  assert_output '== impd 2.1.0 on the host, nixie 0.37.0 (imp-client 2.7.0) in the cluster'
  refute_stderr

  run -0 diff - "$tree/calls" <<< "$(lock_call 0.37.0)"
}

@test "it passes nixie 0 28 0 on a 1 x client beside impd 2" {
  setup_test "$tree"
  write_config "$tree" 2.0.7
  jq -cn --arg lock "$recordings/nixie-bun-lock-imp-client-1.6.2.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.28.0"],
    stdout_file: $lock}' > "$tree/gh-responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" ghcr.io/zgeoff/nixie:0.28.0

  assert_output '== impd 2.0.7 on the host, nixie 0.28.0 (imp-client 1.6.2) in the cluster'
  refute_stderr

  run -0 diff - "$tree/calls" <<< "$(lock_call 0.28.0)"
}

@test "it refuses an impd major bump ahead of the nixie imp client" {
  setup_test "$tree"
  write_config "$tree" 4.0.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-imp-client-3.2.1.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.31.4"],
    stdout_file: $lock}' > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.31.4@$digest"

  refute_output
  assert_stderr 'the switch would run impd 4.0.0, but a nixie pod runs nixie 0.31.4 (imp-client 3.2.1), which accepts impd 3 only; deploy a nixie that speaks impd 4 first (docs/runbooks/workflows.md, Switch the host)'

  run -0 diff - "$tree/calls" <<< "$(lock_call 0.31.4)"
}

@test "it refuses a nixie older than 0 28 0 on a 1 x client beside impd 2" {
  setup_test "$tree"
  write_config "$tree" 2.0.7
  jq -cn --arg lock "$recordings/nixie-bun-lock-imp-client-1.6.2.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.27.9"],
    stdout_file: $lock}' > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.27.9@$digest"

  refute_output
  assert_stderr 'the switch would run impd 2.0.7, but a nixie pod runs nixie 0.27.9 (imp-client 1.6.2), which accepts impd 1 only; deploy a nixie that speaks impd 2 first (docs/runbooks/workflows.md, Switch the host)'

  run -0 diff - "$tree/calls" <<< "$(lock_call 0.27.9)"
}

@test "it refuses a 1 x client beside an impd other than 2" {
  setup_test "$tree"
  write_config "$tree" 3.0.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-imp-client-1.6.2.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.29.3"],
    stdout_file: $lock}' > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.29.3@$digest"

  refute_output
  assert_stderr 'the switch would run impd 3.0.0, but a nixie pod runs nixie 0.29.3 (imp-client 1.6.2), which accepts impd 1, 2 only; deploy a nixie that speaks impd 3 first (docs/runbooks/workflows.md, Switch the host)'

  run -0 diff - "$tree/calls" <<< "$(lock_call 0.29.3)"
}

@test "it passes a nixie whose extra impd majors hold the impd major" {
  setup_test "$tree"
  write_config "$tree" 2.11.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-impz-client-3.0.0.lock" \
    --arg source "$recordings/nixie-build-imp-port-extra-impd-majors-2.txt" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.42.0"],
    stdout_file: $lock}, {
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/adapters/sandbox-imp/src/build-imp-port.ts?ref=v0.42.0"],
    stdout_file: $source}' > "$tree/gh-responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.42.0@$digest"

  assert_output '== impd 2.11.0 on the host, nixie 0.42.0 (imp-client 3.0.0) in the cluster'
  refute_stderr

  run -0 diff - "$tree/calls" << 'EOF'
["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/bun.lock?ref=v0.42.0"]
["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/adapters/sandbox-imp/src/build-imp-port.ts?ref=v0.42.0"]
EOF
}

@test "it reads the extra impd majors from the sandbox folder from nixie 0 72 0" {
  setup_test "$tree"
  write_config "$tree" 4.0.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-impz-client-3.0.0.lock" \
    --arg source "$recordings/nixie-build-imp-port-extra-impd-majors-2-4.txt" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.72.0"],
    stdout_file: $lock}, {
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/adapters/sandbox-imp/src/sandbox/build-imp-port.ts?ref=v0.72.0"],
    stdout_file: $source}' > "$tree/gh-responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.72.0@$digest"

  assert_output '== impd 4.0.0 on the host, nixie 0.72.0 (imp-client 3.0.0) in the cluster'
  refute_stderr

  run -0 diff - "$tree/calls" << 'EOF'
["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/bun.lock?ref=v0.72.0"]
["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/adapters/sandbox-imp/src/sandbox/build-imp-port.ts?ref=v0.72.0"]
EOF
}

@test "it passes a nixie with extra impd majors for its client major without reading its source" {
  setup_test "$tree"
  write_config "$tree" 3.0.2
  jq -cn --arg lock "$recordings/nixie-bun-lock-impz-client-3.0.0.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.42.0"],
    stdout_file: $lock}' > "$tree/gh-responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.42.0@$digest"

  assert_output '== impd 3.0.2 on the host, nixie 0.42.0 (imp-client 3.0.0) in the cluster'
  refute_stderr

  run -0 diff - "$tree/calls" <<< "$(lock_call 0.42.0)"
}

@test "it passes an impd major from extra impd majors that hold several" {
  setup_test "$tree"
  write_config "$tree" 4.0.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-impz-client-3.0.0.lock" \
    --arg source "$recordings/nixie-build-imp-port-extra-impd-majors-2-4.txt" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.43.0"],
    stdout_file: $lock}, {
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/adapters/sandbox-imp/src/build-imp-port.ts?ref=v0.43.0"],
    stdout_file: $source}' > "$tree/gh-responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.43.0@$digest"

  assert_output '== impd 4.0.0 on the host, nixie 0.43.0 (imp-client 3.0.0) in the cluster'
  refute_stderr

  run -0 diff - "$tree/calls" << 'EOF'
["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/bun.lock?ref=v0.43.0"]
["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/adapters/sandbox-imp/src/build-imp-port.ts?ref=v0.43.0"]
EOF
}

@test "it refuses an impd major outside the extra impd majors" {
  setup_test "$tree"
  write_config "$tree" 4.0.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-impz-client-3.0.0.lock" \
    --arg source "$recordings/nixie-build-imp-port-extra-impd-majors-2.txt" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.42.0"],
    stdout_file: $lock}, {
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/adapters/sandbox-imp/src/build-imp-port.ts?ref=v0.42.0"],
    stdout_file: $source}' > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.42.0@$digest"

  refute_output
  assert_stderr 'the switch would run impd 4.0.0, but a nixie pod runs nixie 0.42.0 (imp-client 3.0.0), which accepts impd 2, 3 only; deploy a nixie that speaks impd 4 first (docs/runbooks/workflows.md, Switch the host)'

  run -0 diff - "$tree/calls" << 'EOF'
["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/bun.lock?ref=v0.42.0"]
["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/adapters/sandbox-imp/src/build-imp-port.ts?ref=v0.42.0"]
EOF
}

@test "it refuses a nixie that accepts only impd 3 for an impd 2 switch" {
  setup_test "$tree"
  write_config "$tree" 2.11.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-impz-client-3.0.0.lock" \
    --arg source "$recordings/nixie-build-imp-port-without-extra-impd-majors.txt" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.43.0"],
    stdout_file: $lock}, {
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/adapters/sandbox-imp/src/build-imp-port.ts?ref=v0.43.0"],
    stdout_file: $source}' > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.43.0@$digest"

  refute_output
  assert_stderr 'the switch would run impd 2.11.0, but a nixie pod runs nixie 0.43.0 (imp-client 3.0.0), which accepts impd 3 only; deploy a nixie that speaks impd 2 first (docs/runbooks/workflows.md, Switch the host)'

  run -0 diff - "$tree/calls" << 'EOF'
["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/bun.lock?ref=v0.43.0"]
["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/adapters/sandbox-imp/src/build-imp-port.ts?ref=v0.43.0"]
EOF
}

@test "it refuses a nixie older than 0 42 0 for an impd major other than its client major" {
  setup_test "$tree"
  write_config "$tree" 2.11.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-impz-client-3.0.0.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.41.0"],
    stdout_file: $lock}' > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.41.0@$digest"

  refute_output
  assert_stderr 'the switch would run impd 2.11.0, but a nixie pod runs nixie 0.41.0 (imp-client 3.0.0), which accepts impd 3 only; deploy a nixie that speaks impd 2 first (docs/runbooks/workflows.md, Switch the host)'

  run -0 diff - "$tree/calls" <<< "$(lock_call 0.41.0)"
}

@test "it stops with gh exit code when the imp adapter source cannot be read" {
  setup_test "$tree"
  write_config "$tree" 2.11.0
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed
  # command, such as an API error
  jq -cn --arg lock "$recordings/nixie-bun-lock-impz-client-3.0.0.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.42.0"],
    stdout_file: $lock}, {
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/adapters/sandbox-imp/src/build-imp-port.ts?ref=v0.42.0"],
    stderr: "gh: Not Found (HTTP 404)\n", exit: 1}' > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.42.0@$digest"

  refute_output
  assert_stderr 'gh: Not Found (HTTP 404)'

  run -0 diff - "$tree/calls" << 'EOF'
["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/bun.lock?ref=v0.42.0"]
["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/adapters/sandbox-imp/src/build-imp-port.ts?ref=v0.42.0"]
EOF
}

@test "it refuses when no nixie pod runs" {
  setup_test "$tree"
  write_config "$tree" 3.4.0

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix"

  refute_output
  assert_stderr 'no nixie pod runs, so the switch cannot tell which impd it speaks; wait for its rollout (kubectl -n nixie rollout status statefulset nixie)'

  run -0 diff /dev/null "$tree/calls"
}

@test "it refuses an image that is no nixie release" {
  setup_test "$tree"
  write_config "$tree" 3.4.0

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" ghcr.io/zgeoff/nixie:latest

  refute_output
  assert_stderr "a nixie pod runs 'ghcr.io/zgeoff/nixie:latest', which is no nixie release image"

  run -0 diff /dev/null "$tree/calls"
}

@test "it refuses a lock without the imp client" {
  setup_test "$tree"
  write_config "$tree" 3.4.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-without-imp-client.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.31.4"],
    stdout_file: $lock}' > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" ghcr.io/zgeoff/nixie:0.31.4

  refute_output
  assert_stderr "nixie 0.31.4's bun.lock names no one @impz/client or @zgeoff/imp-client version"

  run -0 diff - "$tree/calls" <<< "$(lock_call 0.31.4)"
}

@test "it stops with gh exit code when the lock cannot be read" {
  setup_test "$tree"
  write_config "$tree" 3.4.0
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed
  # command, such as an API error
  jq -cn '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.31.4"],
    stderr: "gh: Not Found (HTTP 404)\n", exit: 1}' > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" ghcr.io/zgeoff/nixie:0.31.4

  refute_output
  assert_stderr 'gh: Not Found (HTTP 404)'

  run -0 diff - "$tree/calls" <<< "$(lock_call 0.31.4)"
}

@test "it refuses a configuration without the imp host pin" {
  setup_test "$tree"
  echo '  services.imp.enable = true;' > "$tree/configuration.nix"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" ghcr.io/zgeoff/nixie:0.31.4

  refute_output
  assert_stderr "$tree/configuration.nix pins no imp-host release image"

  run -0 diff /dev/null "$tree/calls"
}

@test "it refuses a missing configuration" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" ghcr.io/zgeoff/nixie:0.31.4

  refute_output
  assert_stderr "$tree/configuration.nix is missing, so the switch has no impd pin to compare"
}

@test "it prints its usage without arguments" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script"

  refute_output
  assert_stderr 'usage: check-nixie-impd-major.sh <configuration.nix> [<nixie image>...]'
}
