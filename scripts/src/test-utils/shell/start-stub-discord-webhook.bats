#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for start-stub-discord-webhook.sh: the Discord webhook stand-in takes a JSON post to a
# webhook path with 204 and no body, or with the status <dir>/status sets and Discord's error body,
# records each post's path and body in arrival order, and fails closed on every other request.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'start-stub-discord-webhook.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
  kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true
}

setup_test() {
  local tree="$1"
  mkdir "$tree/discord"
  start_stub_discord_webhook "$tree/discord"
}

@test "it takes a json post with 204 and records its path and body" {
  local code
  setup_test "$tree"

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data '{"content":"first"}' \
    "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a")"
  curl -q --noproxy '*' -sS --max-time 5 -o /dev/null -H 'Content-Type: application/json' \
    --data '{"content":"second"}' "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a"

  assert_equal "$code" 204
  diff /dev/null "$tree/body"
  diff - "$tree/discord/requests" << 'EOF'
POST /api/webhooks/123/token-a
POST /api/webhooks/123/token-a
EOF
  printf '%s' '{"content":"first"}' | diff - "$tree/discord/bodies/1.json"
  printf '%s' '{"content":"second"}' | diff - "$tree/discord/bodies/2.json"
  refute [ -e "$tree/discord/unexpected" ]
  refute [ -L "$tree/discord/unexpected" ]
}

@test "it records each of two posts that arrive together under its own number" {
  local first second
  setup_test "$tree"

  curl -q --noproxy '*' -sS --max-time 5 -o /dev/null -H 'Content-Type: application/json' \
    --data '{"content":"first"}' "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a" 3>&- &
  first=$!
  curl -q --noproxy '*' -sS --max-time 5 -o /dev/null -H 'Content-Type: application/json' \
    --data '{"content":"second"}' "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a" 3>&- &
  second=$!
  wait "$first"
  wait "$second"

  cat "$tree/discord/bodies/1.json" "$tree/discord/bodies/2.json" | jq -r .content | LC_ALL=C sort > "$tree/out"
  diff - "$tree/out" << 'EOF'
first
second
EOF
}

@test "it answers the code its status file holds with discords error body and records the post" {
  local code
  setup_test "$tree"
  echo 500 > "$tree/discord/status"

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data '{"content":"first"}' \
    "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a")"

  assert_equal "$code" 500
  printf '%s' '{"message": "500: stub-discord-webhook", "code": 0}' | diff - "$tree/body"
  diff - "$tree/discord/requests" <<< 'POST /api/webhooks/123/token-a'
  printf '%s' '{"content":"first"}' | diff - "$tree/discord/bodies/1.json"
}

@test "it fails closed on a post to another path" {
  local code
  setup_test "$tree"

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data '{"content":"first"}' \
    "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a/slack")"

  assert_equal "$code" 500
  printf '%s' '{"message":"stub-discord-webhook: unexpected POST /api/webhooks/123/token-a/slack"}' | diff - "$tree/body"
  diff - "$tree/discord/unexpected" <<< 'POST /api/webhooks/123/token-a/slack'
  refute [ -e "$tree/discord/requests" ]
  refute [ -L "$tree/discord/requests" ]
}

@test "it fails closed on a post that is not json" {
  local code
  setup_test "$tree"

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' \
    --data 'content=first' "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a")"

  assert_equal "$code" 500
  printf '%s' '{"message":"stub-discord-webhook: unexpected POST /api/webhooks/123/token-a"}' | diff - "$tree/body"
  diff - "$tree/discord/unexpected" <<< 'POST /api/webhooks/123/token-a'
  refute [ -e "$tree/discord/requests" ]
  refute [ -L "$tree/discord/requests" ]
}

@test "it fails closed on another method" {
  local code
  setup_test "$tree"

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' \
    "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a")"

  assert_equal "$code" 500
  printf '%s' '{"message":"stub-discord-webhook: unexpected GET /api/webhooks/123/token-a"}' | diff - "$tree/body"
  diff - "$tree/discord/unexpected" <<< 'GET /api/webhooks/123/token-a'
  refute [ -e "$tree/discord/requests" ]
  refute [ -L "$tree/discord/requests" ]
}
