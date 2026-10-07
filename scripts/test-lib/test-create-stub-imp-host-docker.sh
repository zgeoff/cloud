#!/usr/bin/env bash
# Test for create-stub-imp-host-docker.sh: the host docker stand-in runs imp's CLI calls
# against impd's state files, adds the glm secret and mints atc-cloud as imp does, fails
# as docker does when imp-host is stopped, and fails closed on any other call. No imp or
# imp-host runs here, so the JSON is pinned as literals of imp's SecretSchema and
# TokenSchema, and the stopped-container error as docker's "Error response from daemon:
# container <id> is not running" with exit 1.
#
#   bash scripts/test-lib/test-create-stub-imp-host-docker.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-imp-host-docker.sh"

it_prints_imps_info_from_its_state_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"version":"0.27.0","features":{"grantableTokens":true}}' > "$tree/impd/info.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" docker exec imp-host imp info --json \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - <(jq -c . "$tree/out") <<< '{"version":"0.27.0","features":{"grantableTokens":true}}'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["docker","exec","imp-host","imp","info","--json"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_lists_the_secrets_from_its_state_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"name":"glm","kind":"custom","rules":[],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" docker exec imp-host imp secret ls --json \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - <(jq -c . "$tree/out") <<< '[{"name":"glm","kind":"custom","rules":[],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_lists_the_tokens_from_its_state_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" docker exec imp-host imp token ls --json \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - <(jq -c . "$tree/out") <<< '[]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_adds_the_glm_secret_from_its_stdin() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/impd/secrets.json"

  echo fixture-zai-key | env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" \
    docker exec -i imp-host imp secret add glm --kind custom --hosts api.z.ai --header authorization \
    --scheme bearer --json > "$tree/out" 2> "$tree/err" || status=$?

  diff - <(jq -c . "$tree/out") <<< '{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z","droppedGrants":0}'
  diff - "$tree/impd/secret-glm" <<< fixture-zai-key
  diff - <(jq -c . "$tree/impd/secrets.json") <<< '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_the_secret_add_with_the_named_error_and_imps_exit_2() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/impd/secrets.json"

  echo fixture-zai-key | env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" \
    STUB_SECRET_ADD_ERROR='imp: secret glm exists' \
    docker exec -i imp-host imp secret add glm --kind custom --hosts api.z.ai --header authorization \
    --scheme bearer --json > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'imp: secret glm exists'
  [ ! -e "$tree/impd/secret-glm" ] || { echo "the failed add stored the key" >&2; exit 1; }
  diff - <(jq -c . "$tree/impd/secrets.json") <<< '[]'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_mints_atc_cloud_and_prints_its_secret_alone_on_stdout() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_MINTED=imp_minted \
    docker exec imp-host imp token new atc-cloud --scope manage --imps 'harness-*' --grantable glm \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< imp_minted
  diff - "$tree/err" <<< 'imp: token atc-cloud made; impd shows its secret only this once'
  diff - <(jq -c . "$tree/impd/tokens.json") <<< '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_the_mint_with_the_named_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_MINTED=imp_minted \
    STUB_TOKEN_NEW_ERROR='imp: token atc-cloud exists' \
    docker exec imp-host imp token new atc-cloud --scope manage --imps 'harness-*' --grantable glm \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'imp: token atc-cloud exists'
  diff - <(jq -c . "$tree/impd/tokens.json") <<< '[]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_the_named_call_as_docker_does_when_imp_host_is_stopped() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_IMPD_FAIL_AT=token-ls \
    docker exec imp-host imp token ls --json > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error response from daemon: container 4f6c0a2e9d1b is not running'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_answers_the_calls_it_is_not_told_to_fail() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[]' > "$tree/impd/secrets.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_IMPD_FAIL_AT=token-ls \
    docker exec imp-host imp secret ls --json > "$tree/out" 2> "$tree/err" || status=$?

  diff - <(jq -c . "$tree/out") <<< '[]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" docker exec imp-host imp token rm atc-cloud \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: exec imp-host imp token rm atc-cloud'
  diff - "$tree/calls" <<< '["docker","exec","imp-host","imp","token","rm","atc-cloud"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, and impd's state directory.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/impd"
  create_stub_imp_host_docker "$tree/bin"
}

run_cases
