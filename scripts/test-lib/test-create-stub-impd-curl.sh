#!/usr/bin/env bash
# Test for create-stub-impd-curl.sh: the host curl stand-in answers impd's tokens.whoami
# for the good bearer and for any other, gives a fixed answer when told to, fails as curl
# does on a reset connection, and fails closed on other arguments. The reset case pins
# the stand-in against the real curl, which start-stub-resetting-listener.sh drives to
# exit 56 with the same output and line, as curl 8.5.0 (CI's
# ubuntu-24.04 runner image 20261004) and 8.22.0 print it. No impd runs here, so the
# identity and 401 bodies are pinned as literals of imp's IdentitySchema and its daemon's
# unauthorized body.
#
#   bash scripts/test-lib/test-create-stub-impd-curl.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-stub-resetting-listener.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-impd-curl.sh"

it_answers_the_good_bearer_with_atc_clouds_identity_and_200() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  echo 'Authorization: Bearer imp_good' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" STUB_GOOD_TOKEN=imp_good curl -q --noproxy '*' -sS --max-time 10 -H @- \
    -H 'content-type: application/json' --data '{"json":{}}' -w '\n%{http_code}' \
    http://127.0.0.1:7070/rpc/tokens/whoami > "$tree/out" 2> "$tree/err" || status=$?

  printf '%s\n%s' '{"json":{"kind":"token","name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}' 200 |
    diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\"json\":{}}","-w","\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_answers_another_bearer_with_impds_401() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  echo 'Authorization: Bearer imp_stale' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" STUB_GOOD_TOKEN=imp_good curl -q --noproxy '*' -sS --max-time 10 -H @- \
    -H 'content-type: application/json' --data '{"json":{}}' -w '\n%{http_code}' \
    http://127.0.0.1:7070/rpc/tokens/whoami > "$tree/out" 2> "$tree/err" || status=$?

  printf '%s\n%s' '{"error":"unauthorized"}' 401 | diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\"json\":{}}","-w","\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_gives_the_named_fixed_answer_for_any_bearer() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  echo 'Authorization: Bearer imp_good' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" STUB_GOOD_TOKEN=imp_good STUB_WHOAMI_STATUS=500 STUB_WHOAMI_BODY='{"error":"internal"}' \
    curl -q --noproxy '*' -sS --max-time 10 -H @- \
    -H 'content-type: application/json' --data '{"json":{}}' -w '\n%{http_code}' \
    http://127.0.0.1:7070/rpc/tokens/whoami > "$tree/out" 2> "$tree/err" || status=$?

  printf '%s\n%s' '{"error":"internal"}' 500 | diff - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\"json\":{}}","-w","\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_as_the_real_curl_does_when_the_connection_is_reset() {
  local status=0 real_status=0
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/listener/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" listener

  echo 'Authorization: Bearer imp_good' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_GOOD_TOKEN=imp_good STUB_CURL_EXIT=56 \
    curl -q --noproxy '*' -sS --max-time 10 -H @- \
    -H 'content-type: application/json' --data '{"json":{}}' -w '\n%{http_code}' \
    http://127.0.0.1:7070/rpc/tokens/whoami > "$tree/out" 2> "$tree/err" || status=$?
  echo 'Authorization: Bearer imp_good' | env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json' \
    --data '{"json":{}}' -w '\n%{http_code}' \
    "http://127.0.0.1:$(cat "$tree/listener/port")/rpc/tokens/whoami" \
    > "$tree/real-out" 2> "$tree/real-err" || real_status=$?

  printf '\n000' | diff - "$tree/out"
  diff - "$tree/err" <<< 'curl: (56) Recv failure: Connection reset by peer'
  diff "$tree/real-out" "$tree/out"
  diff "$tree/real-err" "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\"json\":{}}","-w","\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
CALLS
  [ "$status" = 56 ] || { echo "exit $status, want 56" >&2; exit 1; }
  [ "$real_status" = 56 ] || { echo "the real curl exited $real_status, want 56" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_other_arguments() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  echo 'Authorization: Bearer imp_good' | env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" STUB_GOOD_TOKEN=imp_good curl -sS -H @- http://127.0.0.1:7070/rpc/tokens/whoami \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -sS -H @- http://127.0.0.1:7070/rpc/tokens/whoami'
  diff - "$tree/calls" <<< '["curl","-sS","-H","@-","http://127.0.0.1:7070/rpc/tokens/whoami"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, and the HOME and TMPDIR each curl
# runs with. The config names what a case wires on top: listener, the resetting listener
# the real curl calls, started in <tree>/listener.
setup_test() {
  local tree="$1" part
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_impd_curl "$tree/bin"
  for part in "${@:2}"; do
    case "$part" in
      listener) mkdir "$tree/listener" && start_stub_resetting_listener "$tree/listener" ;;
    esac
  done
}

run_cases
