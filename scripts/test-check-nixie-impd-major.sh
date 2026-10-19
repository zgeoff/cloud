#!/usr/bin/env bash
# Test for check-nixie-impd-major.sh: it passes an impd pin of the nixie imp client's major, and
# nixie 0.28.0 or later on a 1.x client beside impd 2, and refuses an impd major bump ahead of the
# client, an older nixie on a 1.x client beside impd 2, no nixie pod, an image that is no nixie
# release, a lock without the client, a failed lock read, and a configuration.nix without the
# imp-host pin. gh is the stand-in from test-support/shell, which replays the answer each case
# records to the read of a nixie release's bun.lock. Each case writes its own configuration.nix in
# the case tree and runs the script under `env -i`, and compares its stdout, stderr and gh call log.
#
# The recorded locks in test-support/shell/gh-recordings hold `@zgeoff/imp-client` in the catalog
# and the packages, in the line forms bun 1.4 writes (nixie's bun.lock at v0.28.0, read
# 2026-10-16), or no such entry.
#
#   bash scripts/test-check-nixie-impd-major.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-nixie-impd-major.sh"
recordings="$(cd "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/gh-recordings" && pwd)"
digest=sha256:7f3e9c1a5b2d4e6f8a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f

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

it_passes_a_nixie_whose_imp_client_shares_the_impd_major() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_config "$tree" 3.4.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-imp-client-3.2.1.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.31.4"],
    stdout_file: $lock}' > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.31.4@$digest" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "$(lock_call 0.31.4)"
  assert_status 0 "$status"
}

it_passes_nixie_0_28_0_on_a_1_x_client_beside_impd_2() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_config "$tree" 2.0.7
  jq -cn --arg lock "$recordings/nixie-bun-lock-imp-client-1.6.2.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.28.0"],
    stdout_file: $lock}' > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" ghcr.io/zgeoff/nixie:0.28.0 \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '== impd 2.0.7 on the host, nixie 0.28.0 (imp-client 1.6.2) in the cluster'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "$(lock_call 0.28.0)"
  assert_status 0 "$status"
}

it_refuses_an_impd_major_bump_ahead_of_the_nixie_imp_client() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_config "$tree" 4.0.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-imp-client-3.2.1.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.31.4"],
    stdout_file: $lock}' > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.31.4@$digest" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the switch would run impd 4.0.0, but a nixie pod runs nixie 0.31.4, whose imp-client 3.2.1 refuses an impd of another major; deploy a nixie that speaks impd 4 first (docs/runbooks/workflows.md, Switch the host)'
  diff - "$tree/calls" <<< "$(lock_call 0.31.4)"
  assert_status 1 "$status"
}

it_refuses_a_nixie_older_than_0_28_0_on_a_1_x_client_beside_impd_2() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_config "$tree" 2.0.7
  jq -cn --arg lock "$recordings/nixie-bun-lock-imp-client-1.6.2.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.27.9"],
    stdout_file: $lock}' > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.27.9@$digest" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the switch would run impd 2.0.7, but a nixie pod runs nixie 0.27.9, whose imp-client 1.6.2 refuses an impd of another major; deploy a nixie that speaks impd 2 first (docs/runbooks/workflows.md, Switch the host)'
  diff - "$tree/calls" <<< "$(lock_call 0.27.9)"
  assert_status 1 "$status"
}

it_refuses_a_1_x_client_beside_an_impd_other_than_2() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_config "$tree" 3.0.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-imp-client-1.6.2.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.29.3"],
    stdout_file: $lock}' > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "ghcr.io/zgeoff/nixie:0.29.3@$digest" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the switch would run impd 3.0.0, but a nixie pod runs nixie 0.29.3, whose imp-client 1.6.2 refuses an impd of another major; deploy a nixie that speaks impd 3 first (docs/runbooks/workflows.md, Switch the host)'
  diff - "$tree/calls" <<< "$(lock_call 0.29.3)"
  assert_status 1 "$status"
}

it_refuses_when_no_nixie_pod_runs() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_config "$tree" 3.4.0

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'no nixie pod runs, so the switch cannot tell which impd it speaks; wait for its rollout (kubectl -n nixie rollout status statefulset nixie)'
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_refuses_an_image_that_is_no_nixie_release() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_config "$tree" 3.4.0

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" ghcr.io/zgeoff/nixie:latest > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "a nixie pod runs 'ghcr.io/zgeoff/nixie:latest', which is no nixie release image"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_refuses_a_lock_without_the_imp_client() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_config "$tree" 3.4.0
  jq -cn --arg lock "$recordings/nixie-bun-lock-without-imp-client.lock" '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.31.4"],
    stdout_file: $lock}' > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" ghcr.io/zgeoff/nixie:0.31.4 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "nixie 0.31.4's bun.lock names no one @zgeoff/imp-client version"
  diff - "$tree/calls" <<< "$(lock_call 0.31.4)"
  assert_status 1 "$status"
}

it_stops_with_gh_exit_code_when_the_lock_cannot_be_read() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_config "$tree" 3.4.0
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed
  # command, such as an API error
  jq -cn '{
    argv: ["gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/zgeoff/nixie/contents/bun.lock?ref=v0.31.4"],
    stderr: "gh: Not Found (HTTP 404)\n", exit: 1}' > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" ghcr.io/zgeoff/nixie:0.31.4 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'gh: Not Found (HTTP 404)'
  diff - "$tree/calls" <<< "$(lock_call 0.31.4)"
  assert_status 1 "$status"
}

it_refuses_a_configuration_without_the_imp_host_pin() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo '  services.imp.enable = true;' > "$tree/configuration.nix"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" ghcr.io/zgeoff/nixie:0.31.4 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$tree/configuration.nix pins no imp-host release image"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_refuses_a_missing_configuration() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" ghcr.io/zgeoff/nixie:0.31.4 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$tree/configuration.nix is missing, so the switch has no impd pin to compare"
  assert_status 1 "$status"
}

it_prints_its_usage_without_arguments() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: check-nixie-impd-major.sh <configuration.nix> [<nixie image>...]'
  assert_status 2 "$status"
}

run_cases
