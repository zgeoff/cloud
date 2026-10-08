#!/usr/bin/env bash
# Test for create-stub-readiness-curl.sh: the curl stand-in hands out ghcr's pull token,
# answers the tag list by the image's presence and the bearer, answers the public route
# with the named status or curl's timeout, fails both ghcr calls as an unresolved host, and
# fails closed on anything else.
#
#   bash scripts/test-lib/test-create-stub-readiness-curl.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-readiness-curl.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_hands_out_the_pull_token() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    curl -s 'https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull' > "$tree/out" 2> "$tree/err" || status=$?

  printf '%s' '{"token":"ghcr-t1"}' | diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_answers_the_tag_list_with_200_for_a_present_image_and_the_token() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_GHCR_IMAGE=present \
    curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer ghcr-t1' https://ghcr.io/v2/zgeoff/atc-gateway/tags/list > "$tree/out" 2> "$tree/err" || status=$?

  printf '%s' '200' | diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_answers_the_tag_list_with_404_for_an_absent_image() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer ghcr-t1' https://ghcr.io/v2/zgeoff/atc-gateway/tags/list > "$tree/out" 2> "$tree/err" || status=$?

  printf '%s' '404' | diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_answers_the_tag_list_with_401_for_another_bearer() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_GHCR_IMAGE=present \
    curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer other' https://ghcr.io/v2/zgeoff/atc-gateway/tags/list > "$tree/out" 2> "$tree/err" || status=$?

  printf '%s' '401' | diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer other","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_the_token_with_exit_6_and_no_output_when_ghcr_does_not_resolve() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_GHCR_UNREACHABLE=1 \
    curl -s 'https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull' > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["curl","-s","https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull"]'
  [ "$status" = 6 ] || { echo "exit $status, want 6" >&2; exit 1; }
}

it_fails_the_tag_list_with_000_and_exit_6_when_ghcr_does_not_resolve() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_GHCR_UNREACHABLE=1 STUB_GHCR_IMAGE=present \
    curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer ghcr-t1' https://ghcr.io/v2/zgeoff/atc-gateway/tags/list > "$tree/out" 2> "$tree/err" || status=$?

  printf '%s' '000' | diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["curl","-s","-o","/dev/null","-w","%{http_code}","-H","Authorization: Bearer ghcr-t1","https://ghcr.io/v2/zgeoff/atc-gateway/tags/list"]'
  [ "$status" = 6 ] || { echo "exit $status, want 6" >&2; exit 1; }
}

it_answers_the_route_with_the_named_status() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_ROUTE_CODE=530 \
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp > "$tree/out" 2> "$tree/err" || status=$?

  printf '%s' '530' | diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_times_the_route_out_with_000_and_exit_28_without_a_named_status() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp > "$tree/out" 2> "$tree/err" || status=$?

  printf '%s' '000' | diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","10","https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"]'
  [ "$status" = 28 ] || { echo "exit $status, want 28" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    curl -s https://example.com/ > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -s https://example.com/'
  diff - "$tree/calls" <<< '["curl","-s","https://example.com/"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# Pins the stand-in's failure shape to the real curl's: on a failed transfer, -s prints
# nothing but 000 for -w %{http_code}. A dead loopback port is the failure no network
# reaches; its exit code is 7, where the stand-in's timeout and unresolved host use curl's
# documented 28 and 6, which no loopback state produces without waiting out a deadline.
it_prints_000_for_a_failed_transfer_as_the_real_curl_does() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" curl -q --noproxy '*' -s -o /dev/null \
    -w '%{http_code}' http://127.0.0.1:1/ > "$tree/real-out" 2> "$tree/real-err" || true

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/real-out" "$tree/out"
  diff "$tree/real-err" "$tree/err"
  [ "$status" = 28 ] || { echo "exit $status, want 28" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, with fail-closed stand-ins for every
# remote tool, checked so no call can reach a real remote tool, the empty call log, and the
# HOME and TMPDIR the stand-in runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_readiness_curl "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
