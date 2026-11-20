#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for retry-transient-pulumi.sh: it passes a command that succeeds through once, runs it
# again after a pause when it fails on an ACME server's 5xx, a Cloudflare API 5xx to a GET or a
# failed plugin download, writes only the last try's stdout to the --out file, fails at once with
# the command's status on any other error, an ACME 429, a Cloudflare API 5xx to a write or a
# Cloudflare API 4xx, gives up after RETRY_ATTEMPTS tries with the last status, and
# refuses a bad option. The command is a stand-in (create-stub-scripted-command.sh), and the pause
# is create-stub-clock.sh's sleep, first on PATH, which records each pause. Each case runs the
# script under `env -i` and compares its whole stdout, stderr, call log and pauses.
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
  script="$BATS_TEST_DIRNAME/retry-transient-pulumi.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/clock" "$tree/home" "$tree/tmp" "$tree/repo" "$tree/answers"
  : > "$tree/calls"
  create_stub_clock "$tree/clock"
  create_stub_scripted_command "$tree/bin" bun
}

@test "it passes a command that succeeds through once without a pause" {
  setup_test "$tree"
  printf 'Resources:\n    80 unchanged\n' > "$tree/answers/1.out"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" bun run drift -- --suppress-outputs

  assert_output - << 'EOF'
Resources:
    80 unchanged
EOF
  refute_stderr

  run -0 diff - "$tree/calls" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"run\",\"drift\",\"--\",\"--suppress-outputs\"]}"
  refute [ -e "$tree/clock/pauses" ]
  refute [ -L "$tree/clock/pauses" ]
}

@test "it runs the command again in its directory after an acme server s 503" {
  setup_test "$tree"
  mkdir "$tree/deployed"
  printf '%s\n' ' ~  acme:index:Certificate nixie refreshing error:   sdk-v2/provider2.go:572: sdk.helper_schema: acme: error: 503 :: POST :: https://acme-v02.api.letsencrypt.org/acme/new-acct :: urn:ietf:params:acme:error:rateLimited :: Service busy; retry later.: provider=acme@0.18.0' > "$tree/answers/1.err"
  echo 1 > "$tree/answers/1.status"
  printf 'Resources:\n    80 unchanged\n' > "$tree/answers/2.out"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" -C "$tree/deployed" bun run drift -- --suppress-outputs

  assert_output - << 'EOF'
 ~  acme:index:Certificate nixie refreshing error:   sdk-v2/provider2.go:572: sdk.helper_schema: acme: error: 503 :: POST :: https://acme-v02.api.letsencrypt.org/acme/new-acct :: urn:ietf:params:acme:error:rateLimited :: Service busy; retry later.: provider=acme@0.18.0
Resources:
    80 unchanged
EOF
  assert_stderr 'retry-transient-pulumi: try 1 of 3 failed (exit 1) on an error a later try can pass; trying again in 60s'

  run -0 diff - "$tree/calls" << EOF
{"cwd":"$tree/deployed","argv":["bun","run","drift","--","--suppress-outputs"]}
{"cwd":"$tree/deployed","argv":["bun","run","drift","--","--suppress-outputs"]}
EOF
  run -0 diff - "$tree/clock/pauses" <<< '60'
}

@test "it writes only the last try s stdout to the out file after a failed plugin download" {
  setup_test "$tree"
  printf '{"diagnostics":[]}\n' > "$tree/answers/1.out"
  printf '%s\n' "error: could not load provider for resource urn:pulumi:prod::geoff-cloud::acme:index/registration:Registration::nixie-acme: load plugin for acme provider 'urn:pulumi:prod::geoff-cloud::pulumi:providers:acme::letsencrypt': Could not automatically download and install resource plugin 'pulumi-resource-acme' at version v0.18.0: rate limit exceeded: 403 HTTP error fetching plugin from https://api.github.com/repos/pulumiverse/pulumi-acme/releases/tags/v0.18.0" > "$tree/answers/1.err"
  echo 255 > "$tree/answers/1.status"
  printf '{"steps":[{"op":"same"}]}\n' > "$tree/answers/2.out"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" RETRY_DELAY=5 \
    bash "$script" --out "$tree/plan.json" bun run --silent preview -- --refresh --json

  refute_output
  assert_stderr - << 'EOF'
error: could not load provider for resource urn:pulumi:prod::geoff-cloud::acme:index/registration:Registration::nixie-acme: load plugin for acme provider 'urn:pulumi:prod::geoff-cloud::pulumi:providers:acme::letsencrypt': Could not automatically download and install resource plugin 'pulumi-resource-acme' at version v0.18.0: rate limit exceeded: 403 HTTP error fetching plugin from https://api.github.com/repos/pulumiverse/pulumi-acme/releases/tags/v0.18.0
retry-transient-pulumi: try 1 of 3 failed (exit 255) on an error a later try can pass; trying again in 5s
EOF

  run -0 diff - "$tree/plan.json" <<< '{"steps":[{"op":"same"}]}'
  run -0 diff - "$tree/clock/pauses" <<< '5'
}

@test "it matches an error that a json preview writes only to the out file" {
  setup_test "$tree"
  printf '%s\n' '{"diagnostics":[{"message":"acme: error: 503 :: POST :: https://acme-v02.api.letsencrypt.org/acme/new-acct :: urn:ietf:params:acme:error:rateLimited :: Service busy; retry later.","severity":"error"}]}' > "$tree/answers/1.out"
  echo 1 > "$tree/answers/1.status"
  printf '{"steps":[{"op":"same"}]}\n' > "$tree/answers/2.out"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" --out "$tree/plan.json" bun run --silent preview -- --refresh --json

  refute_output
  assert_stderr 'retry-transient-pulumi: try 1 of 3 failed (exit 1) on an error a later try can pass; trying again in 60s'

  run -0 diff - "$tree/plan.json" <<< '{"steps":[{"op":"same"}]}'
}

@test "it fails at once with the command s status on any other error" {
  setup_test "$tree"
  printf 'error: no changes were expected for preview but changes were proposed\n' > "$tree/answers/1.err"
  echo 7 > "$tree/answers/1.status"

  run -7 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" bun run drift -- --suppress-outputs

  assert_output 'error: no changes were expected for preview but changes were proposed'
  refute_stderr

  run -0 diff - "$tree/calls" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"run\",\"drift\",\"--\",\"--suppress-outputs\"]}"
  refute [ -e "$tree/clock/pauses" ]
  refute [ -L "$tree/clock/pauses" ]
}

@test "it fails at once on an acme server s 429 rate limit" {
  setup_test "$tree"
  printf '%s\n' 'acme: error: 429 :: POST :: https://acme-v02.api.letsencrypt.org/acme/new-order :: urn:ietf:params:acme:error:rateLimited :: too many certificates (5) already issued for this exact set of identifiers in the last 168h0m0s' > "$tree/answers/1.err"
  echo 1 > "$tree/answers/1.status"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" bun run drift -- --suppress-outputs

  assert_output 'acme: error: 429 :: POST :: https://acme-v02.api.letsencrypt.org/acme/new-order :: urn:ietf:params:acme:error:rateLimited :: too many certificates (5) already issued for this exact set of identifiers in the last 168h0m0s'
  refute_stderr

  refute [ -e "$tree/clock/pauses" ]

  refute [ -L "$tree/clock/pauses" ]
}

@test "it runs a preview again after a cloudflare api 504 to a get" {
  setup_test "$tree"
  printf '%s\n' 'preview error: error: [ERROR] GET "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/apps/5f6e7d8c-1111-2222-3333-444455556666": 504 Gateway Timeout {"title":"Error 504: Gateway time-out","status":504}' > "$tree/answers/1.err"
  echo 1 > "$tree/answers/1.status"
  printf '{"steps":[{"op":"same"}]}\n' > "$tree/answers/2.out"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" --out "$tree/plan.json" bun run --silent preview -- --refresh --json

  refute_output
  assert_stderr - << 'EOF'
preview error: error: [ERROR] GET "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/apps/5f6e7d8c-1111-2222-3333-444455556666": 504 Gateway Timeout {"title":"Error 504: Gateway time-out","status":504}
retry-transient-pulumi: try 1 of 3 failed (exit 1) on an error a later try can pass; trying again in 60s
EOF

  run -0 diff - "$tree/calls" << EOF
{"cwd":"$tree/repo","argv":["bun","run","--silent","preview","--","--refresh","--json"]}
{"cwd":"$tree/repo","argv":["bun","run","--silent","preview","--","--refresh","--json"]}
EOF
  run -0 diff - "$tree/plan.json" <<< '{"steps":[{"op":"same"}]}'
  run -0 diff - "$tree/clock/pauses" <<< '60'
}

@test "it runs a refresh again after a cloudflare api 502 to a get" {
  setup_test "$tree"
  printf '%s\n' '    error: failed to make http request: GET "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/identity_providers/9a8b7c6d": 502 Bad Gateway' > "$tree/answers/1.err"
  echo 255 > "$tree/answers/1.status"
  printf 'Resources:\n    80 unchanged\n' > "$tree/answers/2.out"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" bun run refresh -- --yes --skip-preview --suppress-outputs

  assert_output - << 'EOF'
    error: failed to make http request: GET "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/identity_providers/9a8b7c6d": 502 Bad Gateway
Resources:
    80 unchanged
EOF
  assert_stderr 'retry-transient-pulumi: try 1 of 3 failed (exit 255) on an error a later try can pass; trying again in 60s'

  run -0 diff - "$tree/clock/pauses" <<< '60'
}

@test "it matches a cloudflare api 503 that a json preview escapes in the out file" {
  setup_test "$tree"
  printf '%s\n' '{"diagnostics":[{"message":"error: [ERROR] GET \"https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/policies/7e6d5c4b\": 503 Service Unavailable","severity":"error"}]}' > "$tree/answers/1.out"
  echo 1 > "$tree/answers/1.status"
  printf '{"steps":[{"op":"same"}]}\n' > "$tree/answers/2.out"

  run -0 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" --out "$tree/plan.json" bun run --silent preview -- --refresh --json

  refute_output
  assert_stderr 'retry-transient-pulumi: try 1 of 3 failed (exit 1) on an error a later try can pass; trying again in 60s'

  run -0 diff - "$tree/plan.json" <<< '{"steps":[{"op":"same"}]}'
}

@test "it fails at once on a cloudflare api 5xx to a write" {
  setup_test "$tree"
  printf '%s\n' 'error: [ERROR] PUT "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/apps/5f6e7d8c": 504 Gateway Timeout' > "$tree/answers/1.err"
  echo 1 > "$tree/answers/1.status"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" bun run drift -- --suppress-outputs

  assert_output 'error: [ERROR] PUT "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/apps/5f6e7d8c": 504 Gateway Timeout'
  refute_stderr

  refute [ -e "$tree/clock/pauses" ]

  refute [ -L "$tree/clock/pauses" ]
}

@test "it fails at once on a cloudflare api 4xx to a get" {
  setup_test "$tree"
  printf '%s\n' 'error: [ERROR] GET "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/apps/5f6e7d8c": 403 Forbidden' > "$tree/answers/1.err"
  echo 1 > "$tree/answers/1.status"

  run -1 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" bun run drift -- --suppress-outputs

  assert_output 'error: [ERROR] GET "https://api.cloudflare.com/client/v4/accounts/0a1b2c3d/access/apps/5f6e7d8c": 403 Forbidden'
  refute_stderr

  refute [ -e "$tree/clock/pauses" ]

  refute [ -L "$tree/clock/pauses" ]
}

@test "it gives up with the last status after the attempts run out" {
  setup_test "$tree"
  printf 'acme: error: 503 :: POST :: x :: urn:ietf:params:acme:error:rateLimited :: Service busy; retry later.\n' > "$tree/answers/1.err"
  echo 1 > "$tree/answers/1.status"
  printf 'acme: error: 502 :: POST :: x :: bad gateway\n' > "$tree/answers/2.err"
  echo 255 > "$tree/answers/2.status"

  run -255 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" RETRY_ATTEMPTS=2 \
    bash "$script" bun run drift

  assert_output - << 'EOF'
acme: error: 503 :: POST :: x :: urn:ietf:params:acme:error:rateLimited :: Service busy; retry later.
acme: error: 502 :: POST :: x :: bad gateway
EOF
  assert_stderr 'retry-transient-pulumi: try 1 of 2 failed (exit 1) on an error a later try can pass; trying again in 60s'

  run -0 diff - "$tree/clock/pauses" <<< '60'
}

@test "it rejects a bad attempt count with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" RETRY_ATTEMPTS=0 \
    bash "$script" bun run drift

  refute_output
  assert_stderr 'usage: retry-transient-pulumi.sh [-C <dir>] [--out <file>] <command…>'

  run -0 diff /dev/null "$tree/calls"
}

@test "it rejects an option without a command with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/repo" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" --out "$tree/plan.json"

  refute_output
  assert_stderr 'usage: retry-transient-pulumi.sh [-C <dir>] [--out <file>] <command…>'

  run -0 diff /dev/null "$tree/calls"
}
