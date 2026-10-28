#!/usr/bin/env bash
# Test for create-stub-kubectl.sh: the kubectl stand-in gets, creates and replaces a Lease in its
# store, answers a missing Lease, an existing one, a stale resourceVersion and an account without
# access with kubectl's errors and exit 1, makes the replace after a race file meet a Conflict, logs each call's argv, and fails
# closed on anything else.
#
#   bash test-support/shell/test-create-stub-kubectl.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-missing.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-kubectl.sh"

lease='{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"example-ns","name":"example-lease"},"spec":{"holderIdentity":"example-holder"}}'

it_creates_a_lease_at_resource_version_1_and_gets_it() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s create --filename - <<< "$lease" > "$tree/out" 2> "$tree/err"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s --namespace example-ns get lease example-lease --output json > "$tree/got" 2>> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'lease.coordination.k8s.io/example-lease created'
  diff /dev/null "$tree/err"
  jq -c . "$tree/got" | diff - <(jq -c '.metadata.resourceVersion = "1"' <<< "$lease")
  diff - "$tree/calls" << 'CALLS'
["kubectl","--request-timeout=30s","create","--filename","-"]
["kubectl","--request-timeout=30s","--namespace","example-ns","get","lease","example-lease","--output","json"]
CALLS
  assert_status 0 "$status"
}

it_fails_a_get_of_a_missing_lease_with_not_found_and_exit_1() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s --namespace example-ns get lease example-lease --output json > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error from server (NotFound): leases.coordination.k8s.io "example-lease" not found'
  assert_status 1 "$status"
}

it_fails_a_get_with_forbidden_and_exit_1_for_an_account_the_forbidden_file_names() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/store"
  echo 'system:serviceaccount:example-ns:example-account' > "$tree/store/forbidden"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s --namespace example-ns get lease example-lease --output json > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error from server (Forbidden): leases.coordination.k8s.io "example-lease" is forbidden: User "system:serviceaccount:example-ns:example-account" cannot get resource "leases" in API group "coordination.k8s.io" in the namespace "example-ns"'
  assert_status 1 "$status"
}

it_fails_a_create_of_an_existing_lease_with_already_exists_and_exit_1() {
  local status=0
  create_case_tree
  setup_test "$tree"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s create --filename - <<< "$lease" > /dev/null

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s create --filename - <<< "$lease" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error from server (AlreadyExists): error when creating "STDIN": leases.coordination.k8s.io "example-lease" already exists'
  assert_status 1 "$status"
}

it_replaces_a_lease_at_its_resource_version_and_moves_the_version_on() {
  local status=0
  create_case_tree
  setup_test "$tree"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s create --filename - <<< "$lease" > /dev/null
  changed='{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"example-ns","name":"example-lease","resourceVersion":"1"},"spec":{}}'

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s replace --filename - <<< "$changed" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'lease.coordination.k8s.io/example-lease replaced'
  diff /dev/null "$tree/err"
  jq -c . "$tree/store/example-ns/example-lease.json" | diff - <(jq -c '.metadata.resourceVersion = "2"' <<< "$changed")
  assert_status 0 "$status"
}

it_fails_a_replace_at_a_stale_resource_version_with_conflict_and_exit_1() {
  local status=0
  create_case_tree
  setup_test "$tree"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s create --filename - <<< "$lease" > /dev/null
  stale='{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"example-ns","name":"example-lease","resourceVersion":"7"},"spec":{}}'

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s replace --filename - <<< "$stale" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error from server (Conflict): error when replacing "STDIN": Operation cannot be fulfilled on leases.coordination.k8s.io "example-lease": the object has been modified; please apply your changes to the latest version and try again'
  jq -c . "$tree/store/example-ns/example-lease.json" | diff - <(jq -c '.metadata.resourceVersion = "1"' <<< "$lease")
  assert_status 1 "$status"
}

it_fails_a_replace_of_a_missing_lease_with_not_found_and_exit_1() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s replace --filename - <<< "$lease" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error from server (NotFound): error when replacing "STDIN": leases.coordination.k8s.io "example-lease" not found'
  assert_status 1 "$status"
}

it_stores_the_race_file_before_the_next_replace_so_that_replace_meets_a_conflict() {
  local status=0
  create_case_tree
  setup_test "$tree"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s create --filename - <<< "$lease" > /dev/null
  jq '.spec.holderIdentity = "example-racer"' <<< "$lease" > "$tree/store/race.json"
  mine='{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"example-ns","name":"example-lease","resourceVersion":"1"},"spec":{}}'

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s replace --filename - <<< "$mine" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error from server (Conflict): error when replacing "STDIN": Operation cannot be fulfilled on leases.coordination.k8s.io "example-lease": the object has been modified; please apply your changes to the latest version and try again'
  jq -c . "$tree/store/example-ns/example-lease.json" |
    diff - <(jq -c '.spec.holderIdentity = "example-racer" | .metadata.resourceVersion = "2"' <<< "$lease")
  assert_missing "$tree/store/race.json" "the race file was kept"
  assert_status 1 "$status"
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s delete lease example-lease > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: --request-timeout=… delete lease example-lease'
  diff - "$tree/calls" <<< '["kubectl","--request-timeout=30s","delete","lease","example-lease"]'
  assert_status 97 "$status"
}

it_fails_closed_with_exit_97_on_a_call_without_a_request_timeout() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl create --filename - <<< "$lease" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: create --filename -'
  assert_missing "$tree/store/example-ns" "the call stored a Lease"
  assert_status 97 "$status"
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_kubectl "$tree/bin" "$tree/store" "$tree/calls"
}

run_cases
