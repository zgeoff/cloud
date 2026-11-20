#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for refresh-prod.sh: with stand-ins for bun and op (create-stub-scripted-command.sh) and the
# real retry-transient-pulumi.sh, it builds the provider in the program checkout and runs
# `op run --env-file=../.env -- pulumi refresh --stack prod --yes --skip-preview --suppress-outputs`
# in its infra/, runs the refresh again after a pause when it fails on a Cloudflare API 502 to a
# GET, stops before the refresh when the provider build fails, and refuses a missing PROGRAM. The
# pause is create-stub-clock.sh's sleep, first on PATH, which records each pause. Each case runs the
# script under `env -i` and compares its whole stdout, stderr, call logs and pauses.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-clock.sh'
  load 'src/test-utils/shell/create-stub-scripted-command.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/refresh-prod.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/clock" "$tree/home" "$tree/tmp" "$tree/repo/program/infra" \
    "$tree/bun-answers" "$tree/op-answers"
  : > "$tree/bun-calls"
  : > "$tree/op-calls"
  create_stub_clock "$tree/clock"
  create_stub_scripted_command "$tree/bin" bun "$tree/bun-calls" "$tree/bun-answers"
  create_stub_scripted_command "$tree/bin" op "$tree/op-calls" "$tree/op-answers"
}

@test "it builds the provider then refreshes the prod stack in infra" {
  setup_test "$tree"
  echo 0 > "$tree/bun-answers/1.status"
  printf 'Resources:\n    80 unchanged\n' > "$tree/op-answers/1.out"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    PROGRAM=program bash "$script"

  assert_output - << 'EOT'
Resources:
    80 unchanged
EOT
  refute_stderr

  run -0 diff - "$tree/bun-calls" <<< "{\"cwd\":\"$tree/repo/program\",\"argv\":[\"bun\",\"run\",\"provider:build\"]}"
  run -0 diff - "$tree/op-calls" <<< "{\"cwd\":\"$tree/repo/program/infra\",\"argv\":[\"op\",\"run\",\"--env-file=../.env\",\"--\",\"pulumi\",\"refresh\",\"--stack\",\"prod\",\"--yes\",\"--skip-preview\",\"--suppress-outputs\"]}"
  refute [ -e "$tree/clock/pauses" ]
  refute [ -L "$tree/clock/pauses" ]
}

@test "it refreshes again after a cloudflare api 502 to a get" {
  setup_test "$tree"
  echo 0 > "$tree/bun-answers/1.status"
  printf '%s\n' '    error: failed to make http request: GET "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/apps/5f6e7d8c": 502 Bad Gateway' > "$tree/op-answers/1.err"
  echo 255 > "$tree/op-answers/1.status"
  printf 'Resources:\n    80 unchanged\n' > "$tree/op-answers/2.out"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    PROGRAM=program bash "$script"

  assert_output - << 'EOT'
    error: failed to make http request: GET "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/apps/5f6e7d8c": 502 Bad Gateway
Resources:
    80 unchanged
EOT
  assert_stderr 'retry-transient-pulumi: try 1 of 3 failed (exit 255) on an error a later try can pass; trying again in 60s'

  run -0 diff - "$tree/bun-calls" <<< "{\"cwd\":\"$tree/repo/program\",\"argv\":[\"bun\",\"run\",\"provider:build\"]}"
  run -0 diff - "$tree/op-calls" << EOT
{"cwd":"$tree/repo/program/infra","argv":["op","run","--env-file=../.env","--","pulumi","refresh","--stack","prod","--yes","--skip-preview","--suppress-outputs"]}
{"cwd":"$tree/repo/program/infra","argv":["op","run","--env-file=../.env","--","pulumi","refresh","--stack","prod","--yes","--skip-preview","--suppress-outputs"]}
EOT
  run -0 diff - "$tree/clock/pauses" <<< '60'
}

@test "it stops before the refresh with the build s status when the provider build fails" {
  setup_test "$tree"
  printf 'go: build failed\n' > "$tree/bun-answers/1.err"
  echo 4 > "$tree/bun-answers/1.status"

  run -4 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    PROGRAM=program bash "$script"

  refute_output
  assert_stderr 'go: build failed'

  run -0 diff /dev/null "$tree/op-calls"
}

@test "it refuses a missing program" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script"

  refute_output
  assert_stderr 'refresh-prod: set PROGRAM'

  run -0 diff /dev/null "$tree/bun-calls"
  run -0 diff /dev/null "$tree/op-calls"
}
