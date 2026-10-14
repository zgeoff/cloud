#!/usr/bin/env bash
# Test for create-stub-publish-docker.sh: the docker stand-in logs each call, takes the login
# password from stdin, records a build and its context, answers a manifest lookup from the test's
# registry files or as docker 29.7.2 does for a missing tag or a failed registry, publishes a push
# with the test's digest, prints a pushed ref's repo digest, answers a push or an inspect of a ref
# with no local image as docker 29.7.2 does, and fails closed on any other call.
#
#   bash test-support/shell/test-create-stub-publish-docker.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-publish-docker.sh"

# setup_test <tree>: the stand-in in <tree>/bin and the HOME and TMPDIR it runs with. It sets
# case_env, the environment every call in a case runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_publish_docker "$tree/bin"
  case_env=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree")
}

it_takes_the_login_password_from_stdin_and_logs_the_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  printf '%s' dummy-token | "${case_env[@]}" docker login ghcr.io -u octocat --password-stdin > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'Login Succeeded'
  diff /dev/null "$tree/err"
  printf '%s' dummy-token | cmp - "$tree/password"
  diff - "$tree/calls" <<< '["docker","login","ghcr.io","-u","octocat","--password-stdin"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_records_a_build_and_the_names_in_its_context() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/context"
  touch "$tree/context/atc-gateway" "$tree/context/Dockerfile"

  "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 -t ghcr.io/zgeoff/atc-gateway:2.27.0 "$tree/context" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/contexts/ghcr.io_zgeoff_atc-gateway_2.27.0" << 'EOF'
Dockerfile
atc-gateway
EOF
  [ -f "$tree/built/ghcr.io_zgeoff_atc-gateway_2.27.0" ]
  diff - "$tree/calls" <<< "[\"docker\",\"build\",\"--build-arg\",\"BASE_IMAGE=example.invalid/base:1\",\"-t\",\"ghcr.io/zgeoff/atc-gateway:2.27.0\",\"$tree/context\"]"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_records_a_build_with_two_build_args() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/context"
  touch "$tree/context/Dockerfile"

  "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 --build-arg GATEWAY_PORT=8414 -t ghcr.io/zgeoff/atc-gateway:2.27.0 "$tree/context" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/contexts/ghcr.io_zgeoff_atc-gateway_2.27.0" <<< 'Dockerfile'
  [ -f "$tree/built/ghcr.io_zgeoff_atc-gateway_2.27.0" ]
  diff - "$tree/calls" <<< "[\"docker\",\"build\",\"--build-arg\",\"BASE_IMAGE=example.invalid/base:1\",\"--build-arg\",\"GATEWAY_PORT=8414\",\"-t\",\"ghcr.io/zgeoff/atc-gateway:2.27.0\",\"$tree/context\"]"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_closed_on_a_build_with_no_tag() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/context"

  "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 --build-arg GATEWAY_PORT=8414 "$tree/context" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: build --build-arg BASE_IMAGE=example.invalid/base:1 --build-arg GATEWAY_PORT=8414 $tree/context"
  [ ! -e "$tree/built/ghcr.io_zgeoff_atc-gateway_2.27.0" ]
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

it_prints_the_manifest_of_a_published_ref() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/registry"
  echo '{"schemaVersion":2}' > "$tree/registry/ghcr.io_zgeoff_atc-gateway_2.27.0"

  "${case_env[@]}" docker manifest inspect ghcr.io/zgeoff/atc-gateway:2.27.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '{"schemaVersion":2}'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["docker","manifest","inspect","ghcr.io/zgeoff/atc-gateway:2.27.0"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_answers_a_missing_tag_as_docker_does() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" docker manifest inspect ghcr.io/zgeoff/atc-gateway:9.9.9 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'manifest unknown'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_every_lookup_with_the_registry_error_the_test_wrote() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/registry"
  echo '{"schemaVersion":2}' > "$tree/registry/ghcr.io_zgeoff_atc-gateway_2.27.0"
  echo 'Get "https://ghcr.io/v2/": dial tcp: lookup ghcr.io: no such host' > "$tree/registry-error"

  "${case_env[@]}" docker manifest inspect ghcr.io/zgeoff/atc-gateway:2.27.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Get "https://ghcr.io/v2/": dial tcp: lookup ghcr.io: no such host'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_publishes_a_built_ref_with_the_digest_the_test_wrote() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/context" "$tree/digests"
  "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 -t ghcr.io/zgeoff/atc-gateway:2.27.0 "$tree/context"
  echo sha256:1111111111111111111111111111111111111111111111111111111111111111 > "$tree/digests/ghcr.io_zgeoff_atc-gateway_2.27.0"

  "${case_env[@]}" docker push ghcr.io/zgeoff/atc-gateway:2.27.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'The push refers to repository [ghcr.io/zgeoff/atc-gateway]'
  diff /dev/null "$tree/err"
  diff - "$tree/registry/ghcr.io_zgeoff_atc-gateway_2.27.0" <<< '{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_answers_a_push_of_a_ref_with_no_local_image_as_docker_does() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/digests"
  echo sha256:1111111111111111111111111111111111111111111111111111111111111111 > "$tree/digests/ghcr.io_zgeoff_atc-gateway_2.27.0"

  "${case_env[@]}" docker push ghcr.io/zgeoff/atc-gateway:2.27.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'The push refers to repository [ghcr.io/zgeoff/atc-gateway]'
  diff - "$tree/err" <<< 'tag does not exist: ghcr.io/zgeoff/atc-gateway:2.27.0'
  [ ! -e "$tree/registry/ghcr.io_zgeoff_atc-gateway_2.27.0" ]
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_prints_the_repo_digest_of_a_pushed_ref() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/context" "$tree/digests"
  echo sha256:1111111111111111111111111111111111111111111111111111111111111111 > "$tree/digests/ghcr.io_zgeoff_atc-gateway_2.27.0"
  "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 -t ghcr.io/zgeoff/atc-gateway:2.27.0 "$tree/context"
  "${case_env[@]}" docker push ghcr.io/zgeoff/atc-gateway:2.27.0 > /dev/null

  "${case_env[@]}" docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/zgeoff/atc-gateway:2.27.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'ghcr.io/zgeoff/atc-gateway@sha256:1111111111111111111111111111111111111111111111111111111111111111'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_answers_an_inspect_of_a_ref_with_no_local_image_as_docker_does() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/zgeoff/atc-gateway:2.27.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error: no such object: ghcr.io/zgeoff/atc-gateway:2.27.0'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_closed_on_an_inspect_of_a_ref_built_but_never_pushed() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/context"
  "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 -t ghcr.io/zgeoff/atc-gateway:2.27.0 "$tree/context"

  "${case_env[@]}" docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/zgeoff/atc-gateway:2.27.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: inspect --format {{index .RepoDigests 0}} ghcr.io/zgeoff/atc-gateway:2.27.0'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

it_fails_closed_on_a_push_with_no_digest_from_the_test() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/context"
  "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 -t ghcr.io/zgeoff/atc-gateway:2.27.0 "$tree/context"

  "${case_env[@]}" docker push ghcr.io/zgeoff/atc-gateway:2.27.0 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: push ghcr.io/zgeoff/atc-gateway:2.27.0'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

it_fails_closed_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" docker run --rm example.invalid/base:1 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: run --rm example.invalid/base:1'
  diff - "$tree/calls" <<< '["docker","run","--rm","example.invalid/base:1"]'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

run_cases
