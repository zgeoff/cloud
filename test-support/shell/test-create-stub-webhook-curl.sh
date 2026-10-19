#!/usr/bin/env bash
# Test for create-stub-webhook-curl.sh: the curl stand-in takes a webhook post as Discord does
# (nothing printed, exit 0) and records its body, fails as curl -fsS does for the HTTP error
# STUB_WEBHOOK_STATUS names, logs every call, and fails closed on any other call.
#
#   bash test-support/shell/test-create-stub-webhook-curl.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-webhook-curl.sh"

it_takes_a_post_and_records_its_body() {
  local status=0
  create_case_tree
  setup_test "$tree"

  printf '{"content":"hi"}\n' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    curl -fsS -H 'Content-Type: application/json' --data @- https://discord.example/api/webhooks/1/t > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/webhook-body" <<< '{"content":"hi"}'
  diff - "$tree/calls" <<< '["curl","-fsS","-H","Content-Type: application/json","--data","@-","https://discord.example/api/webhooks/1/t"]'
  assert_status 0 "$status"
}

it_fails_with_curls_exit_22_for_an_http_error() {
  local status=0
  create_case_tree
  setup_test "$tree"

  printf '{"content":"hi"}\n' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_WEBHOOK_STATUS=404 \
    curl -fsS -H 'Content-Type: application/json' --data @- https://discord.example/api/webhooks/1/t > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 404'
  diff - "$tree/webhook-body" <<< '{"content":"hi"}'
  assert_status 22 "$status"
}

it_fails_closed_with_exit_97_on_a_post_without_f() {
  local status=0
  create_case_tree
  setup_test "$tree"

  printf '{"content":"hi"}\n' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    curl -sS -H 'Content-Type: application/json' --data @- https://discord.example/api/webhooks/1/t > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -sS -H Content-Type: application/json --data @- https://discord.example/api/webhooks/1/t'
  diff - "$tree/calls" <<< '["curl","-sS","-H","Content-Type: application/json","--data","@-","https://discord.example/api/webhooks/1/t"]'
  [ ! -e "$tree/webhook-body" ] || {
    echo "the stand-in recorded a body" >&2
    exit 1
  }
  assert_status 97 "$status"
}

it_fails_closed_with_exit_97_on_a_plain_http_url() {
  local status=0
  create_case_tree
  setup_test "$tree"

  printf '{"content":"hi"}\n' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    curl -fsS -H 'Content-Type: application/json' --data @- http://discord.example/api/webhooks/1/t > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -fsS -H Content-Type: application/json --data @- http://discord.example/api/webhooks/1/t'
  assert_status 97 "$status"
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_webhook_curl "$tree/bin"
}

run_cases
