#!/usr/bin/env bash
# Test for start-stub-discord-webhook.sh: the Discord webhook stand-in takes a JSON post to a
# webhook path with 204 and no body, or with the status <dir>/status sets and Discord's error body,
# records each post's path and body in arrival order, and fails closed on every other request.
#
#   bash test-support/shell/test-start-stub-discord-webhook.sh
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # each create_case_tree cleanup expands when its case exits
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-missing.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-stub-discord-webhook.sh"

it_takes_a_json_post_with_204_and_records_its_path_and_body() {
  local code
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data '{"content":"first"}' \
    "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a")"
  curl -q --noproxy '*' -sS --max-time 5 -o /dev/null -H 'Content-Type: application/json' \
    --data '{"content":"second"}' "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a"

  assert_equals 204 "$code" "the HTTP status"
  diff /dev/null "$tree/body"
  diff - "$tree/discord/requests" << 'EOF'
POST /api/webhooks/123/token-a
POST /api/webhooks/123/token-a
EOF
  printf '%s' '{"content":"first"}' | diff - "$tree/discord/bodies/1.json"
  printf '%s' '{"content":"second"}' | diff - "$tree/discord/bodies/2.json"
  assert_missing "$tree/discord/unexpected" "the post was recorded as unexpected"
}

it_records_each_of_two_posts_that_arrive_together_under_its_own_number() {
  local first second
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"

  curl -q --noproxy '*' -sS --max-time 5 -o /dev/null -H 'Content-Type: application/json' \
    --data '{"content":"first"}' "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a" &
  first=$!
  curl -q --noproxy '*' -sS --max-time 5 -o /dev/null -H 'Content-Type: application/json' \
    --data '{"content":"second"}' "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a" &
  second=$!
  wait "$first"
  wait "$second"

  cat "$tree/discord/bodies/1.json" "$tree/discord/bodies/2.json" | jq -r .content | LC_ALL=C sort > "$tree/out"
  diff - "$tree/out" << 'EOF'
first
second
EOF
}

it_answers_the_code_its_status_file_holds_with_discords_error_body_and_records_the_post() {
  local code
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  echo 500 > "$tree/discord/status"

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data '{"content":"first"}' \
    "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a")"

  assert_equals 500 "$code" "the HTTP status"
  printf '%s' '{"message": "500: stub-discord-webhook", "code": 0}' | diff - "$tree/body"
  diff - "$tree/discord/requests" <<< 'POST /api/webhooks/123/token-a'
  printf '%s' '{"content":"first"}' | diff - "$tree/discord/bodies/1.json"
}

it_fails_closed_on_a_post_to_another_path() {
  local code
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data '{"content":"first"}' \
    "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a/slack")"

  assert_equals 500 "$code" "the HTTP status"
  printf '%s' '{"message":"stub-discord-webhook: unexpected POST /api/webhooks/123/token-a/slack"}' | diff - "$tree/body"
  diff - "$tree/discord/unexpected" <<< 'POST /api/webhooks/123/token-a/slack'
  assert_missing "$tree/discord/requests" "the post was recorded as taken"
}

it_fails_closed_on_a_post_that_is_not_json() {
  local code
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' \
    --data 'content=first' "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a")"

  assert_equals 500 "$code" "the HTTP status"
  printf '%s' '{"message":"stub-discord-webhook: unexpected POST /api/webhooks/123/token-a"}' | diff - "$tree/body"
  diff - "$tree/discord/unexpected" <<< 'POST /api/webhooks/123/token-a'
  assert_missing "$tree/discord/requests" "the post was recorded as taken"
}

it_fails_closed_on_another_method() {
  local code
  create_case_tree 'kill "$(cat "$tree/discord/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"

  code="$(curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" -w '%{http_code}' \
    "http://127.0.0.1:$(cat "$tree/discord/port")/api/webhooks/123/token-a")"

  assert_equals 500 "$code" "the HTTP status"
  printf '%s' '{"message":"stub-discord-webhook: unexpected GET /api/webhooks/123/token-a"}' | diff - "$tree/body"
  diff - "$tree/discord/unexpected" <<< 'GET /api/webhooks/123/token-a'
  assert_missing "$tree/discord/requests" "the request was recorded as taken"
}

setup_test() {
  local tree="$1"
  mkdir "$tree/discord"
  start_stub_discord_webhook "$tree/discord"
}

run_cases
