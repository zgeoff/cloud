#!/usr/bin/env bash
# Test for start-stub-github-api.sh: the GitHub API stand-in answers a release lookup by tag
# with GitHub's 404 and the RepositoryReleaseByTag query with a null release, over HTTPS
# with the certificate it writes, and fails closed on every other request. The last case
# pins what the fixture-image suite assumes about the real gh (2.99.0 here): pointed at the
# stand-in, `gh release download` sends exactly those two lookups and, since both report
# the tag missing, prints "release not found" and exits 1 whichever answer lands first.
#
#   bash scripts/test-lib/test-start-stub-github-api.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/start-stub-github-api.sh"

it_answers_a_release_lookup_by_tag_with_githubs_404() {
  local code
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/github/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    curl -q --noproxy '*' -sS --max-time 5 --cacert "$tree/github/cert.pem" -o "$tree/body" -w '%{http_code}' \
    "https://127.0.0.1:$(cat "$tree/github/port")/api/v3/repos/zgeoff/atc/releases/tags/v1.0.0")"

  printf '%s' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/releases/releases#get-a-release-by-tag-name","status":"404"}' | diff - "$tree/body"
  [ "$code" = 404 ] || { echo "HTTP $code, want 404" >&2; exit 1; }
  diff - "$tree/github/requests" <<< 'GET /api/v3/repos/zgeoff/atc/releases/tags/v1.0.0'
  [ ! -e "$tree/github/unexpected" ] || { echo "the lookup was recorded as unexpected" >&2; exit 1; }
}

it_answers_the_release_by_tag_query_with_a_null_release() {
  local code
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/github/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"

  # shellcheck disable=SC2016 # a GraphQL variable, not a shell one
  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    curl -q --noproxy '*' -sS --max-time 5 --cacert "$tree/github/cert.pem" -o "$tree/body" -w '%{http_code}' \
    --data '{"query":"query RepositoryReleaseByTag($tagName:String!){x}","variables":{"tagName":"v1.0.0"}}' \
    "https://127.0.0.1:$(cat "$tree/github/port")/api/graphql")"

  printf '%s' '{"data":{"repository":{"release":null}}}' | diff - "$tree/body"
  [ "$code" = 200 ] || { echo "HTTP $code, want 200" >&2; exit 1; }
  # shellcheck disable=SC2016 # a GraphQL variable, not a shell one
  diff - "$tree/github/requests" <<< 'POST /api/graphql {"query":"query RepositoryReleaseByTag($tagName:String!){x}","variables":{"tagName":"v1.0.0"}}'
  [ ! -e "$tree/github/unexpected" ] || { echo "the query was recorded as unexpected" >&2; exit 1; }
}

it_fails_closed_on_another_path() {
  local code
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/github/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    curl -q --noproxy '*' -sS --max-time 5 --cacert "$tree/github/cert.pem" -o "$tree/body" -w '%{http_code}' \
    "https://127.0.0.1:$(cat "$tree/github/port")/api/v3/repos/zgeoff/atc/releases/latest")"

  printf '%s' '{"message":"stub-github-api: unexpected GET /api/v3/repos/zgeoff/atc/releases/latest"}' | diff - "$tree/body"
  [ "$code" = 500 ] || { echo "HTTP $code, want 500" >&2; exit 1; }
  diff - "$tree/github/unexpected" <<< 'GET /api/v3/repos/zgeoff/atc/releases/latest'
  [ ! -e "$tree/github/requests" ] || { echo "the request was recorded as answered" >&2; exit 1; }
}

it_fails_closed_on_another_graphql_query() {
  local code
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/github/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    curl -q --noproxy '*' -sS --max-time 5 --cacert "$tree/github/cert.pem" -o "$tree/body" -w '%{http_code}' \
    --data '{"query":"query UserCurrent{viewer{login}}"}' \
    "https://127.0.0.1:$(cat "$tree/github/port")/api/graphql")"

  printf '%s' '{"message":"stub-github-api: unexpected POST /api/graphql"}' | diff - "$tree/body"
  [ "$code" = 500 ] || { echo "HTTP $code, want 500" >&2; exit 1; }
  diff - "$tree/github/unexpected" <<< 'POST /api/graphql'
  [ ! -e "$tree/github/requests" ] || { echo "the query was recorded as answered" >&2; exit 1; }
}

it_fails_closed_on_another_method() {
  local code
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/github/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"

  code="$(env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    curl -q --noproxy '*' -sS --max-time 5 --cacert "$tree/github/cert.pem" -o "$tree/body" -w '%{http_code}' \
    -X DELETE "https://127.0.0.1:$(cat "$tree/github/port")/api/v3/repos/zgeoff/atc/releases/tags/v1.0.0")"

  printf '%s' '{"message":"stub-github-api: unexpected DELETE /api/v3/repos/zgeoff/atc/releases/tags/v1.0.0"}' | diff - "$tree/body"
  [ "$code" = 500 ] || { echo "HTTP $code, want 500" >&2; exit 1; }
  diff - "$tree/github/unexpected" <<< 'DELETE /api/v3/repos/zgeoff/atc/releases/tags/v1.0.0'
}

# gh sends the two lookups at once, so the recorded order is not part of the contract and
# the requests are sorted.
it_makes_a_real_gh_release_download_report_the_release_not_found() {
  local status=0
  tree="$(mktemp -d)"
  trap 'kill "$(cat "$tree/github/pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree"
  mkdir "$tree/gh" "$tree/download"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GH_CONFIG_DIR="$tree/gh" \
    GH_HOST="127.0.0.1:$(cat "$tree/github/port")" SSL_CERT_FILE="$tree/github/cert.pem" \
    gh release download v1.0.0 -R zgeoff/atc -p atc -D "$tree/download" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'release not found'
  sort "$tree/github/requests" > "$tree/requests"
  diff - "$tree/requests" << 'REQUESTS'
GET /api/v3/repos/zgeoff/atc/releases/tags/v1.0.0
POST /api/graphql {"query":"query RepositoryReleaseByTag($name:String!$owner:String!$tagName:String!){repository(owner: $owner, name: $name){release(tagName: $tagName){databaseId,isDraft}}}","variables":{"name":"atc","owner":"zgeoff","tagName":"v1.0.0"}}
REQUESTS
  [ ! -e "$tree/github/unexpected" ] || { echo "gh sent an unexpected request" >&2; exit 1; }
  ls -A "$tree/download" > "$tree/downloaded"
  diff /dev/null "$tree/downloaded"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# Runtime every case needs: the stand-in, started in <tree>/github, and the HOME and TMPDIR
# each client runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/github" "$tree/home" "$tree/tmp"
  start_stub_github_api "$tree/github"
}

run_cases
