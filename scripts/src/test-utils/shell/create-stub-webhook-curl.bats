#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-webhook-curl.sh: the curl stand-in takes a webhook post as Discord does
# (nothing printed, exit 0) and records its body, fails as curl -fsS does for the HTTP error
# STUB_WEBHOOK_STATUS names, logs every call, and fails closed on any other call.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-webhook-curl.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_webhook_curl "$tree/bin"
}

@test "it takes a post and records its body" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    curl -fsS -H 'Content-Type: application/json' --data @- https://discord.example/api/webhooks/1/t <<< '{"content":"hi"}'

  refute_output
  refute_stderr
  diff - "$tree/webhook-body" <<< '{"content":"hi"}'
  diff - "$tree/calls" <<< '["curl","-fsS","-H","Content-Type: application/json","--data","@-","https://discord.example/api/webhooks/1/t"]'
}

@test "it fails with curls exit 22 for an http error" {
  setup_test "$tree"

  run -22 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_WEBHOOK_STATUS=404 \
    curl -fsS -H 'Content-Type: application/json' --data @- https://discord.example/api/webhooks/1/t <<< '{"content":"hi"}'

  refute_output
  assert_stderr 'curl: (22) The requested URL returned error: 404'
  diff - "$tree/webhook-body" <<< '{"content":"hi"}'
}

@test "it fails closed with exit 97 on a post without f" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    curl -sS -H 'Content-Type: application/json' --data @- https://discord.example/api/webhooks/1/t <<< '{"content":"hi"}'

  refute_output
  assert_stderr 'unexpected: -sS -H Content-Type: application/json --data @- https://discord.example/api/webhooks/1/t'
  diff - "$tree/calls" <<< '["curl","-sS","-H","Content-Type: application/json","--data","@-","https://discord.example/api/webhooks/1/t"]'
  refute [ -e "$tree/webhook-body" ]
}

@test "it fails closed with exit 97 on a plain http url" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    curl -fsS -H 'Content-Type: application/json' --data @- http://discord.example/api/webhooks/1/t <<< '{"content":"hi"}'

  refute_output
  assert_stderr 'unexpected: -fsS -H Content-Type: application/json --data @- http://discord.example/api/webhooks/1/t'
}
