#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-nix-docker.sh: the docker stand-in logs every call, answers the
# nix build and copy that switch-geoffcloud.sh runs, fails closed on any other call, and
# hands a call to the real docker when asked. The last case pins what the switch suite
# assumes about the real docker CLI with no daemon socket: the whole stderr naming the socket
# and the exit status, as docker 28.0.4 (CI's ubuntu-24.04 runner image 20261004: a help line,
# exit 125) or docker 29.7.2 (one line, exit 1) prints them; the `docker version` cases pin
# each version's client version on stdout, its socket error on stderr and exit 1, checked
# against those two docker CLIs, docker 29.4.2 (CI's ubuntu-26.04 runner image 20261101) and
# docker 29.8.2 (the cloud imp's), which both print 29.7.2's socket error.
# matches_one_version accepts each version's whole stdout and stderr only with that
# version's exit status. No nix runs here; a failed build's
# or copy's exit 1 is the one the stand-in's header records from a one-off check against
# nix 2.35.2.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-nix-docker.sh'
  load '../../../nix-image.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
  [ -z "${short_tree:-}" ] || rm -rf "$short_tree"
}

# use_short_tree: puts the case tree under /tmp, not $TMPDIR: the real docker meets a socket in
# this tree, and a socket path past 107 bytes, the most sun_path holds, makes docker 29.7.2 panic
# or print another error
use_short_tree() {
  short_tree="$(mktemp -d -p /tmp)"
  tree="$short_tree"
}

# matches_one_version <name> <status> <stdout> <stderr>…: passes when the status, stdout and
# stderr of the last run together equal those of one version, each given as its name, exit
# status, whole stdout and whole stderr. It fails with the run's and each version's, so one
# version's text never passes with another version's status.
matches_one_version() {
  local report=""
  while [ "$#" -gt 0 ]; do
    if [ "$status" = "$2" ] && [ "$output" = "$3" ] && [ "$stderr" = "$4" ]; then
      return 0
    fi
    report+=$'\n'"not $1: exit $2, stdout '$3', stderr '$4'"
    shift 4
  done
  fail "matches none of the supported outputs: exit $status, stdout '$output', stderr '$stderr'$report"
}

# Runtime every case needs: the stand-in in <tree>/bin, and the HOME and TMPDIR it runs
# with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_nix_docker "$tree/bin"
}

@test "it copies the build mount and prints the build output" {
  setup_test "$tree"
  mkdir "$tree/src"
  echo committed > "$tree/src/marker"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_BUILD_SAW="$tree/saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-test \
    docker run --rm -v "$tree/src:/src:ro" "$NIX_IMAGE" nix build --no-link --print-out-paths path:.

  refute_stderr
  assert_output /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-test
  diff - "$tree/saw/marker" <<< committed
  diff - "$tree/calls" << CALLS
["docker","run","--rm","-v","$tree/src:/src:ro","$NIX_IMAGE","nix","build","--no-link","--print-out-paths","path:."]
CALLS
}

@test "it edits the named file before it copies the build mount" {
  setup_test "$tree"
  mkdir "$tree/src"
  echo committed > "$tree/src/marker"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_BUILD_SAW="$tree/saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-test \
    STUB_EDIT_DURING_BUILD="$tree/src/marker" \
    docker run --rm -v "$tree/src:/src:ro" "$NIX_IMAGE" nix build --no-link --print-out-paths path:.

  refute_stderr
  assert_output /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-test
  diff - "$tree/saw/marker" <<< edited
  diff - "$tree/calls" << CALLS
["docker","run","--rm","-v","$tree/src:/src:ro","$NIX_IMAGE","nix","build","--no-link","--print-out-paths","path:."]
CALLS
}

@test "it fails a build with the named error and exit 1" {
  setup_test "$tree"
  mkdir "$tree/src"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_BUILD_SAW="$tree/saw" \
    STUB_BUILD_ERROR="error: builder for '/nix/store/x.drv' failed with exit code 1" \
    docker run --rm -v "$tree/src:/src:ro" "$NIX_IMAGE" nix build --no-link --print-out-paths path:.

  refute_output
  assert_stderr "error: builder for '/nix/store/x.drv' failed with exit code 1"
  [ -d "$tree/saw" ]
  diff - "$tree/calls" << CALLS
["docker","run","--rm","-v","$tree/src:/src:ro","$NIX_IMAGE","nix","build","--no-link","--print-out-paths","path:."]
CALLS
}

@test "it answers a copy with nothing" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    docker run --rm "$NIX_IMAGE" nix copy --to ssh://root@geoffcloud /nix/store/x

  refute_output
  refute_stderr
  diff - "$tree/calls" << CALLS
["docker","run","--rm","$NIX_IMAGE","nix","copy","--to","ssh://root@geoffcloud","/nix/store/x"]
CALLS
}

@test "it fails a copy with the named error and exit 1" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_COPY_ERROR="error: cannot connect to 'root@geoffcloud'" \
    docker run --rm "$NIX_IMAGE" nix copy --to ssh://root@geoffcloud /nix/store/x

  refute_output
  assert_stderr "error: cannot connect to 'root@geoffcloud'"
  diff - "$tree/calls" << CALLS
["docker","run","--rm","$NIX_IMAGE","nix","copy","--to","ssh://root@geoffcloud","/nix/store/x"]
CALLS
}

@test "it fails closed with exit 97 on any other call" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" docker ps -a

  refute_output
  assert_stderr 'unexpected: ps -a'
  diff - "$tree/calls" <<< '["docker","ps","-a"]'
}

@test "it hands a logged call to the real docker which fails without a daemon at its socket" {
  use_short_tree
  setup_test "$tree"

  run --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_DOCKER_PASS=1 DOCKER_HOST="unix://$tree/docker.sock" \
    docker run --rm "$NIX_IMAGE" nix build --no-link --print-out-paths path:.

  # docker 28.0.4 exits 125 for a run it cannot start, and docker 29.7.2 exits 1
  matches_one_version \
    "docker 28.0.4" 125 '' "docker: Cannot connect to the Docker daemon at unix://$tree/docker.sock. Is the docker daemon running?

Run 'docker run --help' for more information" \
    "docker 29.7.2" 1 '' "failed to connect to the docker API at unix://$tree/docker.sock; check if the path is correct and if the daemon is running: dial unix $tree/docker.sock: connect: no such file or directory"
  diff - "$tree/calls" << CALLS
["docker","run","--rm","$NIX_IMAGE","nix","build","--no-link","--print-out-paths","path:."]
CALLS
}

# With no DOCKER_HOST the real docker would reach the machine's daemon; a broken guard
# here runs only `docker version`, which pulls nothing.
@test "it never hands a call to the real docker without a DOCKER HOST" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_DOCKER_PASS=1 \
    docker version

  refute_output
  assert_stderr 'unexpected: version (DOCKER_HOST=)'
  diff - "$tree/calls" <<< '["docker","version"]'
}

@test "it never hands a call to the real docker for a socket outside the case tree" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_DOCKER_PASS=1 \
    DOCKER_HOST=unix:///var/run/docker.sock docker version

  refute_output
  assert_stderr 'unexpected: version (DOCKER_HOST=unix:///var/run/docker.sock)'
  diff - "$tree/calls" <<< '["docker","version"]'
}

# The `..` climbs out of the case tree to a socket path under its parent that does not
# exist, so even a broken guard would reach no daemon.
@test "it never hands a call to the real docker for a socket that climbs out of the case tree" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_DOCKER_PASS=1 \
    DOCKER_HOST="unix://$tree/../$(basename "$tree")-outside/docker.sock" docker version

  refute_output
  assert_stderr "unexpected: version (DOCKER_HOST=unix://$tree/../$(basename "$tree")-outside/docker.sock)"
  diff - "$tree/calls" <<< '["docker","version"]'
}

@test "it hands a call to the real docker with the socket path normalised" {
  use_short_tree
  setup_test "$tree"
  mkdir "$tree/sub"

  run --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_DOCKER_PASS=1 \
    DOCKER_HOST="unix://$tree/sub/../docker.sock" docker version --format '{{.Client.Version}}'

  local err28 err29
  err28="Cannot connect to the Docker daemon at unix://$tree/docker.sock. Is the docker daemon running?"
  err29="failed to connect to the docker API at unix://$tree/docker.sock; check if the path is correct and if the daemon is running: dial unix $tree/docker.sock: connect: no such file or directory"
  # docker 28.0.4, 29.4.2, 29.7.2 and 29.8.2 each print their client version and exit 1; the fake
  # docker would print "fake docker" and exit 0
  matches_one_version \
    "docker 28.0.4" 1 28.0.4 "$err28" \
    "docker 29.7.2" 1 29.7.2 "$err29" \
    "docker 29.4.2" 1 29.4.2 "$err29" \
    "docker 29.8.2" 1 29.8.2 "$err29"
  diff - "$tree/calls" <<< '["docker","version","--format","{{.Client.Version}}"]'
}

@test "it never hands a call to the real docker for a tcp host" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_DOCKER_PASS=1 \
    DOCKER_HOST=tcp://127.0.0.1:1 docker version

  refute_output
  assert_stderr 'unexpected: version (DOCKER_HOST=tcp://127.0.0.1:1)'
  diff - "$tree/calls" <<< '["docker","version"]'
}

@test "it hands a call to the system docker not one on the callers PATH" {
  use_short_tree
  mkdir "$tree/bin" "$tree/fake" "$tree/home" "$tree/tmp"
  printf '#!/usr/bin/env bash\necho fake docker\n' > "$tree/fake/docker"
  chmod +x "$tree/fake/docker"
  PATH="$tree/fake:$PATH" create_stub_nix_docker "$tree/bin"

  run --separate-stderr env -i PATH="$tree/bin:$tree/fake:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_DOCKER_PASS=1 DOCKER_HOST="unix://$tree/docker.sock" docker version --format '{{.Client.Version}}'

  local err28 err29
  err28="Cannot connect to the Docker daemon at unix://$tree/docker.sock. Is the docker daemon running?"
  err29="failed to connect to the docker API at unix://$tree/docker.sock; check if the path is correct and if the daemon is running: dial unix $tree/docker.sock: connect: no such file or directory"
  # docker 28.0.4, 29.4.2, 29.7.2 and 29.8.2 each print their client version and exit 1; the fake
  # docker would print "fake docker" and exit 0
  matches_one_version \
    "docker 28.0.4" 1 28.0.4 "$err28" \
    "docker 29.7.2" 1 29.7.2 "$err29" \
    "docker 29.4.2" 1 29.4.2 "$err29" \
    "docker 29.8.2" 1 29.8.2 "$err29"
  diff - "$tree/calls" <<< '["docker","version","--format","{{.Client.Version}}"]'
}
