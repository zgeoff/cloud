#!/usr/bin/env bash
# Test for retry-transient-pulumi.sh: it passes a command that succeeds through once, runs it
# again after a pause when it fails on an ACME server's 5xx or a failed plugin download, writes
# only the last try's stdout to the --out file, fails at once with the command's status on any
# other error or an ACME 429, gives up after RETRY_ATTEMPTS tries with the last status, and
# refuses a bad option. The command is a stand-in (create-stub-scripted-command.sh), and the pause
# is create-stub-clock.sh's sleep, first on PATH, which records each pause. Each case runs the
# script under `env -i` and compares its whole stdout, stderr, call log and pauses.
#
#   bash scripts/test-retry-transient-pulumi.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-clock.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-scripted-command.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/retry-transient-pulumi.sh"

it_passes_a_command_that_succeeds_through_once_without_a_pause() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf 'Resources:\n    80 unchanged\n' > "$tree/answers/1.out"

  (cd "$tree/repo" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" bun run drift -- --suppress-outputs) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
Resources:
    80 unchanged
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"run\",\"drift\",\"--\",\"--suppress-outputs\"]}"
  [ ! -e "$tree/clock/pauses" ] || {
    echo "it paused: $(cat "$tree/clock/pauses")" >&2
    exit 1
  }
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_runs_the_command_again_in_its_directory_after_an_acme_server_s_503() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/deployed"
  printf '%s\n' ' ~  acme:index:Certificate nixie refreshing error:   sdk-v2/provider2.go:572: sdk.helper_schema: acme: error: 503 :: POST :: https://acme-v02.api.letsencrypt.org/acme/new-acct :: urn:ietf:params:acme:error:rateLimited :: Service busy; retry later.: provider=acme@0.18.0' > "$tree/answers/1.err"
  echo 1 > "$tree/answers/1.status"
  printf 'Resources:\n    80 unchanged\n' > "$tree/answers/2.out"

  (cd "$tree/repo" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" -C "$tree/deployed" bun run drift -- --suppress-outputs) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
 ~  acme:index:Certificate nixie refreshing error:   sdk-v2/provider2.go:572: sdk.helper_schema: acme: error: 503 :: POST :: https://acme-v02.api.letsencrypt.org/acme/new-acct :: urn:ietf:params:acme:error:rateLimited :: Service busy; retry later.: provider=acme@0.18.0
Resources:
    80 unchanged
EOF
  diff - "$tree/err" <<< 'retry-transient-pulumi: try 1 of 3 failed (exit 1) on an error a later try can pass; trying again in 60s'
  diff - "$tree/calls" << EOF
{"cwd":"$tree/deployed","argv":["bun","run","drift","--","--suppress-outputs"]}
{"cwd":"$tree/deployed","argv":["bun","run","drift","--","--suppress-outputs"]}
EOF
  diff - "$tree/clock/pauses" <<< '60'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_writes_only_the_last_try_s_stdout_to_the_out_file_after_a_failed_plugin_download() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '{"diagnostics":[]}\n' > "$tree/answers/1.out"
  printf '%s\n' "error: could not load provider for resource urn:pulumi:prod::geoff-cloud::acme:index/registration:Registration::nixie-acme: load plugin for acme provider 'urn:pulumi:prod::geoff-cloud::pulumi:providers:acme::letsencrypt': Could not automatically download and install resource plugin 'pulumi-resource-acme' at version v0.18.0: rate limit exceeded: 403 HTTP error fetching plugin from https://api.github.com/repos/pulumiverse/pulumi-acme/releases/tags/v0.18.0" > "$tree/answers/1.err"
  echo 255 > "$tree/answers/1.status"
  printf '{"steps":[{"op":"same"}]}\n' > "$tree/answers/2.out"

  (cd "$tree/repo" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" RETRY_DELAY=5 \
    bash "$script" --out "$tree/plan.json" bun run --silent preview -- --refresh --json) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
error: could not load provider for resource urn:pulumi:prod::geoff-cloud::acme:index/registration:Registration::nixie-acme: load plugin for acme provider 'urn:pulumi:prod::geoff-cloud::pulumi:providers:acme::letsencrypt': Could not automatically download and install resource plugin 'pulumi-resource-acme' at version v0.18.0: rate limit exceeded: 403 HTTP error fetching plugin from https://api.github.com/repos/pulumiverse/pulumi-acme/releases/tags/v0.18.0
retry-transient-pulumi: try 1 of 3 failed (exit 255) on an error a later try can pass; trying again in 5s
EOF
  diff - "$tree/plan.json" <<< '{"steps":[{"op":"same"}]}'
  diff - "$tree/clock/pauses" <<< '5'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_matches_an_error_that_a_json_preview_writes_only_to_the_out_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '%s\n' '{"diagnostics":[{"message":"acme: error: 503 :: POST :: https://acme-v02.api.letsencrypt.org/acme/new-acct :: urn:ietf:params:acme:error:rateLimited :: Service busy; retry later.","severity":"error"}]}' > "$tree/answers/1.out"
  echo 1 > "$tree/answers/1.status"
  printf '{"steps":[{"op":"same"}]}\n' > "$tree/answers/2.out"

  (cd "$tree/repo" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" --out "$tree/plan.json" bun run --silent preview -- --refresh --json) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'retry-transient-pulumi: try 1 of 3 failed (exit 1) on an error a later try can pass; trying again in 60s'
  diff - "$tree/plan.json" <<< '{"steps":[{"op":"same"}]}'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_at_once_with_the_command_s_status_on_any_other_error() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf 'error: no changes were expected for preview but changes were proposed\n' > "$tree/answers/1.err"
  echo 7 > "$tree/answers/1.status"

  (cd "$tree/repo" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" bun run drift -- --suppress-outputs) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'error: no changes were expected for preview but changes were proposed'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"run\",\"drift\",\"--\",\"--suppress-outputs\"]}"
  [ ! -e "$tree/clock/pauses" ] || {
    echo "it paused: $(cat "$tree/clock/pauses")" >&2
    exit 1
  }
  [ "$status" = 7 ] || {
    echo "exit $status, want 7" >&2
    exit 1
  }
}

it_fails_at_once_on_an_acme_server_s_429_rate_limit() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '%s\n' 'acme: error: 429 :: POST :: https://acme-v02.api.letsencrypt.org/acme/new-order :: urn:ietf:params:acme:error:rateLimited :: too many certificates (5) already issued for this exact set of identifiers in the last 168h0m0s' > "$tree/answers/1.err"
  echo 1 > "$tree/answers/1.status"

  (cd "$tree/repo" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" bun run drift -- --suppress-outputs) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'acme: error: 429 :: POST :: https://acme-v02.api.letsencrypt.org/acme/new-order :: urn:ietf:params:acme:error:rateLimited :: too many certificates (5) already issued for this exact set of identifiers in the last 168h0m0s'
  diff /dev/null "$tree/err"
  [ ! -e "$tree/clock/pauses" ] || {
    echo "it paused: $(cat "$tree/clock/pauses")" >&2
    exit 1
  }
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_gives_up_with_the_last_status_after_the_attempts_run_out() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf 'acme: error: 503 :: POST :: x :: urn:ietf:params:acme:error:rateLimited :: Service busy; retry later.\n' > "$tree/answers/1.err"
  echo 1 > "$tree/answers/1.status"
  printf 'acme: error: 502 :: POST :: x :: bad gateway\n' > "$tree/answers/2.err"
  echo 255 > "$tree/answers/2.status"

  (cd "$tree/repo" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" RETRY_ATTEMPTS=2 \
    bash "$script" bun run drift) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
acme: error: 503 :: POST :: x :: urn:ietf:params:acme:error:rateLimited :: Service busy; retry later.
acme: error: 502 :: POST :: x :: bad gateway
EOF
  diff - "$tree/err" <<< 'retry-transient-pulumi: try 1 of 2 failed (exit 1) on an error a later try can pass; trying again in 60s'
  diff - "$tree/clock/pauses" <<< '60'
  [ "$status" = 255 ] || {
    echo "exit $status, want 255" >&2
    exit 1
  }
}

it_rejects_a_bad_attempt_count_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" RETRY_ATTEMPTS=0 \
    bash "$script" bun run drift) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: retry-transient-pulumi.sh [-C <dir>] [--out <file>] <command…>'
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_rejects_an_option_without_a_command_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_LOG="$tree/calls" STUB_ANSWERS="$tree/answers" \
    bash "$script" --out "$tree/plan.json") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: retry-transient-pulumi.sh [-C <dir>] [--out <file>] <command…>'
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/clock" "$tree/home" "$tree/tmp" "$tree/repo" "$tree/answers"
  : > "$tree/calls"
  create_stub_clock "$tree/clock"
  create_stub_scripted_command "$tree/bin" bun
}

run_cases
