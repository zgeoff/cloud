#!/usr/bin/env bash
# Test for Grafana's MCP account in the real engine: the pinned Grafana that the chart in
# create-metrics.ts runs (its grafana subchart's appVersion), with a service account made from the
# arguments that build-mcp-account-args.ts builds, and a token for that account. Each case sends one
# request with the token and compares the HTTP status that Grafana answers: the account reads, and
# Grafana refuses its writes.
#
#   bash scripts/run-shell-suites.sh alert-rules
#   CASE='folder' bash infra/observability/test-mcp-account.sh
#
# shell-suite: alert-rules
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/wait-for.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/pick-port.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/create-case-tree.sh"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
grafana_image='docker.io/grafana/grafana:13.2.3@sha256:b28bae15e219c998fb0e0424ed724930cc61b1f61fb404d47c862f9a23f9e572'
run_id="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"

# setup_test <tree>: Grafana on a loopback port of the host network, as the chart's user and with
# every call out to the internet off, the account that the repo's builder describes, and the
# account's token in a curl header file
setup_test() {
  local tree="$1" account_id key admin_password
  port="$(pick_port)"
  admin_password="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  # header files, so neither secret reaches a command line
  printf 'Authorization: Basic %s\n' "$(printf 'admin:%s' "$admin_password" | base64 -w0)" \
    > "$tree/admin-header"
  (cd "$repo" && bun -e "
    import { buildMCPAccountArgs } from './infra/observability/build-mcp-account-args.ts';
    console.log(JSON.stringify(buildMCPAccountArgs()));
  ") > "$tree/account.json"
  # pulled here, so a cold image cache never writes its progress into a case's compared output
  docker pull -q "$grafana_image" > /dev/null
  container="mcp-account-grafana-$run_id-$BASHPID"
  GF_SECURITY_ADMIN_PASSWORD="$admin_password" docker run -d --name "$container" --network host \
    --user 472:472 --cap-drop ALL --security-opt no-new-privileges -e GF_SECURITY_ADMIN_PASSWORD \
    -e GF_SERVER_HTTP_ADDR=127.0.0.1 -e "GF_SERVER_HTTP_PORT=$port" \
    -e GF_ANALYTICS_REPORTING_ENABLED=false -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    -e GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false -e GF_PLUGINS_PREINSTALL_DISABLED=true \
    -e GF_NEWS_NEWS_FEED_ENABLED=false \
    "$grafana_image" > /dev/null
  wait_for 120 "Grafana" curl -fs -o /dev/null "http://127.0.0.1:$port/api/health"
  account_id="$(curl -fsS -H @"$tree/admin-header" -H 'Content-Type: application/json' \
    --data @"$tree/account.json" "http://127.0.0.1:$port/api/serviceaccounts" | jq -er .id)"
  key="$(curl -fsS -H @"$tree/admin-header" -H 'Content-Type: application/json' \
    --data '{"name":"mcp-viewer"}' "http://127.0.0.1:$port/api/serviceaccounts/$account_id/tokens" |
    jq -er .key)"
  printf 'Authorization: Bearer %s\n' "$key" > "$tree/auth-header"
}

remove_grafana() {
  if [ -n "${container:-}" ]; then docker rm -f "$container" > /dev/null 2>&1 || true; fi
}

# read_status <tree> <method> <path> [<JSON body>]: sends the request with the account's token and
# prints the HTTP status that Grafana answers
read_status() {
  local tree="$1" method="$2" path="$3"
  local body=()
  if [ "$#" -gt 3 ]; then body=(--data "$4"); fi
  curl -sS -o "$tree/response.json" -w '%{http_code}' -X "$method" -H @"$tree/auth-header" \
    -H 'Content-Type: application/json' "${body[@]}" "http://127.0.0.1:$port$path"
}

it_lets_the_account_list_the_datasources() {
  create_case_tree remove_grafana
  setup_test "$tree"

  assert_equals 200 "$(read_status "$tree" GET /api/datasources)" "status"
}

it_refuses_the_account_a_new_folder() {
  create_case_tree remove_grafana
  setup_test "$tree"

  assert_equals 403 "$(read_status "$tree" POST /api/folders '{"title":"Release notes"}')" "status"
}

it_refuses_the_account_a_new_datasource() {
  create_case_tree remove_grafana
  setup_test "$tree"

  assert_equals 403 "$(read_status "$tree" POST /api/datasources \
    '{"name":"Tempo","type":"tempo","url":"http://127.0.0.1:1","access":"proxy"}')" "status"
}

it_refuses_the_account_a_new_service_account() {
  create_case_tree remove_grafana
  setup_test "$tree"

  assert_equals 403 "$(read_status "$tree" POST /api/serviceaccounts \
    '{"name":"build-bot","role":"Admin"}')" "status"
}

run_cases
