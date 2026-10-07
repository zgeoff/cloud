#!/usr/bin/env bash
# Test for start-stub-impd.sh: the impd stand-in answers tokens.whoami as impd does for
# the good bearer, for any other, and for any bearer when it holds no good one, and fails
# closed on every other request. No impd
# runs here, so the identity and 401 bodies are pinned as literals of imp's IdentitySchema
# and its daemon's unauthorized body.
#
#   bash scripts/test-lib/test-start-stub-impd.sh
#   SEED=1234 bash scripts/test-lib/test-start-stub-impd.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/build-token.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-stub-impd.sh"

it_answers_whoami_with_atc_clouds_identity_for_the_good_bearer() {
  local seed="$1" code
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/impd/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree"' EXIT
  setup_test "$tree"
  build_token "$seed" good > "$tree/impd/good-token"

  code="$(printf 'Authorization: Bearer %s\n' "$(build_token "$seed" good)" |
    env -i PATH=/usr/bin:/bin curl -q --noproxy '*' -sS --max-time 5 -H @- --data '{"json":{}}' \
      -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$(cat "$tree/impd/port")/rpc/tokens/whoami")"

  diff - <(cat "$tree/body"; echo) <<< '{"json":{"kind":"token","name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}'
  [ "$code" = 200 ] || { echo "HTTP $code, want 200" >&2; exit 1; }
  [ ! -e "$tree/impd/unexpected" ] || { echo "whoami was recorded as unexpected" >&2; exit 1; }
}

it_answers_whoami_with_401_for_another_bearer() {
  local seed="$1" code
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/impd/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree"' EXIT
  setup_test "$tree"
  build_token "$seed" good > "$tree/impd/good-token"

  code="$(printf 'Authorization: Bearer %s\n' "$(build_token "$seed" stale)" |
    env -i PATH=/usr/bin:/bin curl -q --noproxy '*' -sS --max-time 5 -H @- --data '{"json":{}}' \
      -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$(cat "$tree/impd/port")/rpc/tokens/whoami")"

  diff - <(cat "$tree/body"; echo) <<< '{"error":"unauthorized"}'
  [ "$code" = 401 ] || { echo "HTTP $code, want 401" >&2; exit 1; }
  [ ! -e "$tree/impd/unexpected" ] || { echo "whoami was recorded as unexpected" >&2; exit 1; }
}

it_answers_whoami_with_401_while_it_holds_no_good_bearer() {
  local seed="$1" code
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/impd/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree"' EXIT
  setup_test "$tree"

  code="$(printf 'Authorization: Bearer %s\n' "$(build_token "$seed" good)" |
    env -i PATH=/usr/bin:/bin curl -q --noproxy '*' -sS --max-time 5 -H @- --data '{"json":{}}' \
      -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$(cat "$tree/impd/port")/rpc/tokens/whoami")"

  diff - <(cat "$tree/body"; echo) <<< '{"error":"unauthorized"}'
  [ "$code" = 401 ] || { echo "HTTP $code, want 401" >&2; exit 1; }
}

it_answers_whoami_with_401_for_no_bearer_while_it_holds_no_good_bearer() {
  local code
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/impd/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree"' EXIT
  setup_test "$tree"

  code="$(env -i PATH=/usr/bin:/bin curl -q --noproxy '*' -sS --max-time 5 --data '{"json":{}}' \
    -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$(cat "$tree/impd/port")/rpc/tokens/whoami")"

  diff - <(cat "$tree/body"; echo) <<< '{"error":"unauthorized"}'
  [ "$code" = 401 ] || { echo "HTTP $code, want 401" >&2; exit 1; }
}

it_fails_closed_on_a_post_to_another_path_and_records_it() {
  local seed="$1" code
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/impd/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree"' EXIT
  setup_test "$tree"
  build_token "$seed" good > "$tree/impd/good-token"

  code="$(printf 'Authorization: Bearer %s\n' "$(build_token "$seed" good)" |
    env -i PATH=/usr/bin:/bin curl -q --noproxy '*' -sS --max-time 5 -H @- --data '{"json":{}}' \
      -o "$tree/body" -w '%{http_code}' "http://127.0.0.1:$(cat "$tree/impd/port")/rpc/tokens/list")"

  diff - <(cat "$tree/body"; echo) <<< '{"error":"stub-impd: unexpected POST /rpc/tokens/list"}'
  diff - "$tree/impd/unexpected" <<< 'POST /rpc/tokens/list'
  [ "$code" = 500 ] || { echo "HTTP $code, want 500" >&2; exit 1; }
}

it_fails_closed_on_a_get_of_whoami_and_records_it() {
  local seed="$1" code
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/impd/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree"' EXIT
  setup_test "$tree"
  build_token "$seed" good > "$tree/impd/good-token"

  code="$(env -i PATH=/usr/bin:/bin curl -q --noproxy '*' -sS --max-time 5 -o "$tree/body" \
    -w '%{http_code}' "http://127.0.0.1:$(cat "$tree/impd/port")/rpc/tokens/whoami")"

  diff - <(cat "$tree/body"; echo) <<< '{"error":"stub-impd: unexpected GET /rpc/tokens/whoami"}'
  diff - "$tree/impd/unexpected" <<< 'GET /rpc/tokens/whoami'
  [ "$code" = 500 ] || { echo "HTTP $code, want 500" >&2; exit 1; }
}

# Runtime every case needs: the stand-in, started in <tree>/impd.
setup_test() {
  local tree="$1"
  mkdir "$tree/impd"
  start_stub_impd "$tree/impd"
}

seed="${SEED:-$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')}"
echo "seed $seed (rerun with SEED=$seed)"
run_cases "$seed"
