#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-kubectl.sh: the kubectl stand-in gets, creates and replaces a Lease in its
# store, answers a missing Lease, an existing one, a stale resourceVersion and an account without
# access with kubectl's errors and exit 1, makes the replace after a race file meet a Conflict, logs each call's argv, and fails
# closed on anything else.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-kubectl.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  lease='{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"example-ns","name":"example-lease"},"spec":{"holderIdentity":"example-holder"}}'
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_kubectl "$tree/bin" "$tree/store" "$tree/calls"
}

@test "it creates a lease at resource version 1 and gets it" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s create --filename - <<< "$lease"
  assert_output 'lease.coordination.k8s.io/example-lease created'
  refute_stderr
  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s --namespace example-ns get lease example-lease --output json
  refute_stderr
  jq -c . <<< "$output" | diff - <(jq -c '.metadata.resourceVersion = "1"' <<< "$lease")
  diff - "$tree/calls" << 'CALLS'
["kubectl","--request-timeout=30s","create","--filename","-"]
["kubectl","--request-timeout=30s","--namespace","example-ns","get","lease","example-lease","--output","json"]
CALLS
}

@test "it fails a get of a missing lease with not found and exit 1" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s --namespace example-ns get lease example-lease --output json

  refute_output
  assert_stderr 'Error from server (NotFound): leases.coordination.k8s.io "example-lease" not found'
}

@test "it fails a get with forbidden and exit 1 for an account the forbidden file names" {
  setup_test "$tree"
  mkdir -p "$tree/store"
  echo 'system:serviceaccount:example-ns:example-account' > "$tree/store/forbidden"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s --namespace example-ns get lease example-lease --output json

  refute_output
  assert_stderr 'Error from server (Forbidden): leases.coordination.k8s.io "example-lease" is forbidden: User "system:serviceaccount:example-ns:example-account" cannot get resource "leases" in API group "coordination.k8s.io" in the namespace "example-ns"'
}

@test "it fails a create of an existing lease with already exists and exit 1" {
  setup_test "$tree"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s create --filename - <<< "$lease" > /dev/null

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s create --filename - <<< "$lease"

  refute_output
  assert_stderr 'Error from server (AlreadyExists): error when creating "STDIN": leases.coordination.k8s.io "example-lease" already exists'
}

@test "it replaces a lease at its resource version and moves the version on" {
  setup_test "$tree"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s create --filename - <<< "$lease" > /dev/null
  changed='{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"example-ns","name":"example-lease","resourceVersion":"1"},"spec":{}}'

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s replace --filename - <<< "$changed"

  assert_output 'lease.coordination.k8s.io/example-lease replaced'
  refute_stderr
  jq -c . "$tree/store/example-ns/example-lease.json" | diff - <(jq -c '.metadata.resourceVersion = "2"' <<< "$changed")
}

@test "it fails a replace at a stale resource version with conflict and exit 1" {
  setup_test "$tree"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s create --filename - <<< "$lease" > /dev/null
  stale='{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"example-ns","name":"example-lease","resourceVersion":"7"},"spec":{}}'

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s replace --filename - <<< "$stale"

  refute_output
  assert_stderr 'Error from server (Conflict): error when replacing "STDIN": Operation cannot be fulfilled on leases.coordination.k8s.io "example-lease": the object has been modified; please apply your changes to the latest version and try again'
  jq -c . "$tree/store/example-ns/example-lease.json" | diff - <(jq -c '.metadata.resourceVersion = "1"' <<< "$lease")
}

@test "it fails a replace of a missing lease with not found and exit 1" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s replace --filename - <<< "$lease"

  refute_output
  assert_stderr 'Error from server (NotFound): error when replacing "STDIN": leases.coordination.k8s.io "example-lease" not found'
}

@test "it stores the race file before the next replace so that replace meets a conflict" {
  setup_test "$tree"
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s create --filename - <<< "$lease" > /dev/null
  jq '.spec.holderIdentity = "example-racer"' <<< "$lease" > "$tree/store/race.json"
  mine='{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"namespace":"example-ns","name":"example-lease","resourceVersion":"1"},"spec":{}}'

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s replace --filename - <<< "$mine"

  refute_output
  assert_stderr 'Error from server (Conflict): error when replacing "STDIN": Operation cannot be fulfilled on leases.coordination.k8s.io "example-lease": the object has been modified; please apply your changes to the latest version and try again'
  jq -c . "$tree/store/example-ns/example-lease.json" |
    diff - <(jq -c '.spec.holderIdentity = "example-racer" | .metadata.resourceVersion = "2"' <<< "$lease")
  refute [ -e "$tree/store/race.json" ]
  refute [ -L "$tree/store/race.json" ]
}

@test "it fails closed with exit 97 on any other call" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl --request-timeout=30s delete lease example-lease

  refute_output
  assert_stderr 'unexpected: --request-timeout=… delete lease example-lease'
  diff - "$tree/calls" <<< '["kubectl","--request-timeout=30s","delete","lease","example-lease"]'
}

@test "it fails closed with exit 97 on a call without a request timeout" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" kubectl create --filename - <<< "$lease"

  refute_output
  assert_stderr 'unexpected: create --filename -'
  refute [ -e "$tree/store/example-ns" ]
  refute [ -L "$tree/store/example-ns" ]
}
