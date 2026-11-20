#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for start-stub-github-api.sh: the GitHub API stand-in answers a release lookup by tag
# with GitHub's 404 and the RepositoryReleaseByTag query with a null release, over HTTPS
# with the certificate it writes, records each by method, path and tag, and fails closed on
# every other request. The last case pins what the fixture-image suite assumes about the
# real gh: pointed at the stand-in, `gh release download` sends exactly those two lookups
# for the tag and, since both report it missing, prints "release not found" and exits 1
# whichever answer lands first. It ran against gh 2.99.0 here; CI's ubuntu-24.04 runner
# image (20260927.320.1, per its published readme) lists GitHub CLI 2.101.0. gh runs with
# telemetry and the update check off and trusts only the stand-in's certificate. The runner
# image installs gh in /usr/bin and the cloud imp's agent image in /usr/local/bin, so the case's
# PATH holds both.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'start-stub-github-api.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
  kill "$(cat "$tree/github/pid" 2> /dev/null)" 2> /dev/null || true
}

# Runtime every case needs: the stand-in, started in <tree>/github, and the HOME and TMPDIR
# each client runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/github" "$tree/home" "$tree/tmp"
  start_stub_github_api "$tree/github" 3>&-
}

@test "it answers a release lookup by tag with githubs 404" {
  local code
  setup_test "$tree"

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    curl -q --noproxy '*' -sS --max-time 5 --cacert "$tree/github/cert.pem" -o "$tree/body" -w '%{http_code}' \
    "https://127.0.0.1:$(cat "$tree/github/port")/api/v3/repos/zgeoff/atc/releases/tags/v1.0.0")"

  printf '%s' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/releases/releases#get-a-release-by-tag-name","status":"404"}' | diff - "$tree/body"
  assert_equal "$code" 404
  diff - "$tree/github/requests" <<< 'GET /api/v3/repos/zgeoff/atc/releases/tags/v1.0.0'
  refute [ -e "$tree/github/unexpected" ]
  refute [ -L "$tree/github/unexpected" ]
}

@test "it answers the release by tag query with a null release" {
  local code
  setup_test "$tree"

  # shellcheck disable=SC2016 # a GraphQL variable, not a shell one
  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    curl -q --noproxy '*' -sS --max-time 5 --cacert "$tree/github/cert.pem" -o "$tree/body" -w '%{http_code}' \
    --data '{"query":"query RepositoryReleaseByTag($tagName:String!){x}","variables":{"tagName":"v1.0.0"}}' \
    "https://127.0.0.1:$(cat "$tree/github/port")/api/graphql")"

  printf '%s' '{"data":{"repository":{"release":null}}}' | diff - "$tree/body"
  assert_equal "$code" 200
  diff - "$tree/github/requests" <<< 'POST /api/graphql RepositoryReleaseByTag tagName=v1.0.0'
  refute [ -e "$tree/github/unexpected" ]
  refute [ -L "$tree/github/unexpected" ]
}

@test "it fails closed on another path" {
  local code
  setup_test "$tree"

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    curl -q --noproxy '*' -sS --max-time 5 --cacert "$tree/github/cert.pem" -o "$tree/body" -w '%{http_code}' \
    "https://127.0.0.1:$(cat "$tree/github/port")/api/v3/repos/zgeoff/atc/releases/latest")"

  printf '%s' '{"message":"stub-github-api: unexpected GET /api/v3/repos/zgeoff/atc/releases/latest"}' | diff - "$tree/body"
  assert_equal "$code" 500
  diff - "$tree/github/unexpected" <<< 'GET /api/v3/repos/zgeoff/atc/releases/latest'
  refute [ -e "$tree/github/requests" ]
  refute [ -L "$tree/github/requests" ]
}

@test "it fails closed on another graphql query" {
  local code
  setup_test "$tree"

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    curl -q --noproxy '*' -sS --max-time 5 --cacert "$tree/github/cert.pem" -o "$tree/body" -w '%{http_code}' \
    --data '{"query":"query UserCurrent{viewer{login}}"}' \
    "https://127.0.0.1:$(cat "$tree/github/port")/api/graphql")"

  printf '%s' '{"message":"stub-github-api: unexpected POST /api/graphql"}' | diff - "$tree/body"
  assert_equal "$code" 500
  diff - "$tree/github/unexpected" <<< 'POST /api/graphql'
  refute [ -e "$tree/github/requests" ]
  refute [ -L "$tree/github/requests" ]
}

@test "it fails closed on another method" {
  local code
  setup_test "$tree"

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    curl -q --noproxy '*' -sS --max-time 5 --cacert "$tree/github/cert.pem" -o "$tree/body" -w '%{http_code}' \
    -X DELETE "https://127.0.0.1:$(cat "$tree/github/port")/api/v3/repos/zgeoff/atc/releases/tags/v1.0.0")"

  printf '%s' '{"message":"stub-github-api: unexpected DELETE /api/v3/repos/zgeoff/atc/releases/tags/v1.0.0"}' | diff - "$tree/body"
  assert_equal "$code" 500
  diff - "$tree/github/unexpected" <<< 'DELETE /api/v3/repos/zgeoff/atc/releases/tags/v1.0.0'
  refute [ -e "$tree/github/requests" ]
  refute [ -L "$tree/github/requests" ]
}

@test "it fails closed on the release by tag query without a tag variable" {
  local code
  setup_test "$tree"

  # shellcheck disable=SC2016 # a GraphQL variable, not a shell one
  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    curl -q --noproxy '*' -sS --max-time 5 --cacert "$tree/github/cert.pem" -o "$tree/body" -w '%{http_code}' \
    --data '{"query":"query RepositoryReleaseByTag($tagName:String!){x}","variables":{}}' \
    "https://127.0.0.1:$(cat "$tree/github/port")/api/graphql")"

  printf '%s' '{"message":"stub-github-api: unexpected POST /api/graphql"}' | diff - "$tree/body"
  assert_equal "$code" 500
  diff - "$tree/github/unexpected" <<< 'POST /api/graphql'
  refute [ -e "$tree/github/requests" ]
  refute [ -L "$tree/github/requests" ]
}

# gh sends the two lookups at once, so the recorded order is not part of the contract and
# the requests are sorted.
@test "it makes a real gh release download report the release not found" {
  setup_test "$tree"
  mkdir "$tree/gh" "$tree/download" "$tree/no-certs"

  run -1 --separate-stderr env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GH_CONFIG_DIR="$tree/gh" \
    GH_TELEMETRY=0 DO_NOT_TRACK=1 GH_NO_UPDATE_NOTIFIER=1 \
    GH_HOST="127.0.0.1:$(cat "$tree/github/port")" SSL_CERT_FILE="$tree/github/cert.pem" \
    SSL_CERT_DIR="$tree/no-certs" gh release download v1.0.0 -R zgeoff/atc -p atc -D "$tree/download"

  refute_output
  assert_stderr 'release not found'
  sort "$tree/github/requests" > "$tree/requests"
  diff - "$tree/requests" << 'REQUESTS'
GET /api/v3/repos/zgeoff/atc/releases/tags/v1.0.0
POST /api/graphql RepositoryReleaseByTag tagName=v1.0.0
REQUESTS
  refute [ -e "$tree/github/unexpected" ]
  refute [ -L "$tree/github/unexpected" ]
  ls -A "$tree/download" > "$tree/downloaded"
  diff /dev/null "$tree/downloaded"
}
