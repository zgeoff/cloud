#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-publish-docker.sh: the docker stand-in logs each call, takes the login
# password from stdin, records a build and its context, answers a manifest lookup from the test's
# registry files or as docker 29.7.2 does for a missing tag or a failed registry, publishes a push
# with the test's digest, prints a pushed ref's repo digest, answers a push or an inspect of a ref
# with no local image as docker 29.7.2 does, and fails closed on any other call.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-publish-docker.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# setup_test <tree>: the stand-in in <tree>/bin and the HOME and TMPDIR it runs with. It sets
# case_env, the environment every call in a case runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_publish_docker "$tree/bin"
  case_env=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree")
}

@test "it takes the login password from stdin and logs the call" {
  setup_test "$tree"

  run -0 --separate-stderr "${case_env[@]}" docker login ghcr.io -u octocat --password-stdin < <(printf '%s' dummy-token)

  assert_output 'Login Succeeded'
  refute_stderr
  printf '%s' dummy-token | cmp - "$tree/password"
  diff - "$tree/calls" <<< '["docker","login","ghcr.io","-u","octocat","--password-stdin"]'
}

@test "it records a build and the names in its context" {
  setup_test "$tree"
  mkdir "$tree/context"
  touch "$tree/context/atc-gateway" "$tree/context/Dockerfile"

  run -0 --separate-stderr "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 -t ghcr.io/zgeoff/atc-gateway:2.27.0 "$tree/context"

  refute_output
  refute_stderr
  diff - "$tree/contexts/ghcr.io_zgeoff_atc-gateway_2.27.0" << 'EOF'
Dockerfile
atc-gateway
EOF
  [ -f "$tree/built/ghcr.io_zgeoff_atc-gateway_2.27.0" ]
  diff - "$tree/calls" <<< "[\"docker\",\"build\",\"--build-arg\",\"BASE_IMAGE=example.invalid/base:1\",\"-t\",\"ghcr.io/zgeoff/atc-gateway:2.27.0\",\"$tree/context\"]"
}

@test "it records a build with two build args" {
  setup_test "$tree"
  mkdir "$tree/context"
  touch "$tree/context/Dockerfile"

  run -0 --separate-stderr "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 --build-arg GATEWAY_PORT=8414 -t ghcr.io/zgeoff/atc-gateway:2.27.0 "$tree/context"

  refute_output
  refute_stderr
  diff - "$tree/contexts/ghcr.io_zgeoff_atc-gateway_2.27.0" <<< 'Dockerfile'
  [ -f "$tree/built/ghcr.io_zgeoff_atc-gateway_2.27.0" ]
  diff - "$tree/calls" <<< "[\"docker\",\"build\",\"--build-arg\",\"BASE_IMAGE=example.invalid/base:1\",\"--build-arg\",\"GATEWAY_PORT=8414\",\"-t\",\"ghcr.io/zgeoff/atc-gateway:2.27.0\",\"$tree/context\"]"
}

@test "it fails closed on a build with no tag" {
  setup_test "$tree"
  mkdir "$tree/context"

  run -97 --separate-stderr "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 --build-arg GATEWAY_PORT=8414 "$tree/context"

  refute_output
  assert_stderr "unexpected: build --build-arg BASE_IMAGE=example.invalid/base:1 --build-arg GATEWAY_PORT=8414 $tree/context"
  [ ! -e "$tree/built/ghcr.io_zgeoff_atc-gateway_2.27.0" ]
}

@test "it prints the manifest of a published ref" {
  setup_test "$tree"
  mkdir "$tree/registry"
  echo '{"schemaVersion":2}' > "$tree/registry/ghcr.io_zgeoff_atc-gateway_2.27.0"

  run -0 --separate-stderr "${case_env[@]}" docker manifest inspect ghcr.io/zgeoff/atc-gateway:2.27.0

  assert_output '{"schemaVersion":2}'
  refute_stderr
  diff - "$tree/calls" <<< '["docker","manifest","inspect","ghcr.io/zgeoff/atc-gateway:2.27.0"]'
}

@test "it answers a missing tag as docker does" {
  setup_test "$tree"

  run -1 --separate-stderr "${case_env[@]}" docker manifest inspect ghcr.io/zgeoff/atc-gateway:9.9.9

  refute_output
  assert_stderr 'manifest unknown'
}

@test "it fails every lookup with the registry error the test wrote" {
  setup_test "$tree"
  mkdir "$tree/registry"
  echo '{"schemaVersion":2}' > "$tree/registry/ghcr.io_zgeoff_atc-gateway_2.27.0"
  echo 'Get "https://ghcr.io/v2/": dial tcp: lookup ghcr.io: no such host' > "$tree/registry-error"

  run -1 --separate-stderr "${case_env[@]}" docker manifest inspect ghcr.io/zgeoff/atc-gateway:2.27.0

  refute_output
  assert_stderr 'Get "https://ghcr.io/v2/": dial tcp: lookup ghcr.io: no such host'
}

@test "it publishes a built ref with the digest the test wrote" {
  setup_test "$tree"
  mkdir "$tree/context" "$tree/digests"
  "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 -t ghcr.io/zgeoff/atc-gateway:2.27.0 "$tree/context"
  echo sha256:1111111111111111111111111111111111111111111111111111111111111111 > "$tree/digests/ghcr.io_zgeoff_atc-gateway_2.27.0"

  run -0 --separate-stderr "${case_env[@]}" docker push ghcr.io/zgeoff/atc-gateway:2.27.0

  assert_output 'The push refers to repository [ghcr.io/zgeoff/atc-gateway]'
  refute_stderr
  diff - "$tree/registry/ghcr.io_zgeoff_atc-gateway_2.27.0" <<< '{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}'
}

@test "it answers a push of a ref with no local image as docker does" {
  setup_test "$tree"
  mkdir "$tree/digests"
  echo sha256:1111111111111111111111111111111111111111111111111111111111111111 > "$tree/digests/ghcr.io_zgeoff_atc-gateway_2.27.0"

  run -1 --separate-stderr "${case_env[@]}" docker push ghcr.io/zgeoff/atc-gateway:2.27.0

  assert_output 'The push refers to repository [ghcr.io/zgeoff/atc-gateway]'
  assert_stderr 'tag does not exist: ghcr.io/zgeoff/atc-gateway:2.27.0'
  [ ! -e "$tree/registry/ghcr.io_zgeoff_atc-gateway_2.27.0" ]
}

@test "it prints the repo digest of a pushed ref" {
  setup_test "$tree"
  mkdir "$tree/context" "$tree/digests"
  echo sha256:1111111111111111111111111111111111111111111111111111111111111111 > "$tree/digests/ghcr.io_zgeoff_atc-gateway_2.27.0"
  "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 -t ghcr.io/zgeoff/atc-gateway:2.27.0 "$tree/context"
  "${case_env[@]}" docker push ghcr.io/zgeoff/atc-gateway:2.27.0 > /dev/null

  run -0 --separate-stderr "${case_env[@]}" docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/zgeoff/atc-gateway:2.27.0

  assert_output 'ghcr.io/zgeoff/atc-gateway@sha256:1111111111111111111111111111111111111111111111111111111111111111'
  refute_stderr
}

@test "it answers an inspect of a ref with no local image as docker does" {
  setup_test "$tree"

  run -1 --separate-stderr "${case_env[@]}" docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/zgeoff/atc-gateway:2.27.0

  refute_output
  assert_stderr 'Error: no such object: ghcr.io/zgeoff/atc-gateway:2.27.0'
}

@test "it fails closed on an inspect of a ref built but never pushed" {
  setup_test "$tree"
  mkdir "$tree/context"
  "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 -t ghcr.io/zgeoff/atc-gateway:2.27.0 "$tree/context"

  run -97 --separate-stderr "${case_env[@]}" docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/zgeoff/atc-gateway:2.27.0

  refute_output
  assert_stderr 'unexpected: inspect --format {{index .RepoDigests 0}} ghcr.io/zgeoff/atc-gateway:2.27.0'
}

@test "it fails closed on a push with no digest from the test" {
  setup_test "$tree"
  mkdir "$tree/context"
  "${case_env[@]}" docker build --build-arg BASE_IMAGE=example.invalid/base:1 -t ghcr.io/zgeoff/atc-gateway:2.27.0 "$tree/context"

  run -97 --separate-stderr "${case_env[@]}" docker push ghcr.io/zgeoff/atc-gateway:2.27.0

  refute_output
  assert_stderr 'unexpected: push ghcr.io/zgeoff/atc-gateway:2.27.0'
}

@test "it fails closed on any other call" {
  setup_test "$tree"

  run -97 --separate-stderr "${case_env[@]}" docker run --rm example.invalid/base:1

  refute_output
  assert_stderr 'unexpected: run --rm example.invalid/base:1'
  diff - "$tree/calls" <<< '["docker","run","--rm","example.invalid/base:1"]'
}
