#!/usr/bin/env bash
# Test for create-stub-nix-docker.sh: the docker stand-in logs every call, answers the
# nix build and copy that switch-geoffcloud.sh runs, fails closed on any other call, and
# hands a call to the real docker when asked. The last case pins what the switch suite
# assumes about the real docker CLI with no daemon socket: exit 1 and the whole stderr naming
# the socket, as docker 28.0.4 (CI's ubuntu-24.04 runner image 20261004, with a help line) or
# docker 29.7.2 (one line) prints it. No nix runs here, so a failed build's exit 1 is nix's documented exit
# for a failed build, not pinned against nix.
#
#   bash scripts/test-lib/test-create-stub-nix-docker.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-nix-docker.sh"

it_copies_the_build_mount_and_prints_the_build_output() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/src"
  echo committed > "$tree/src/marker"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_LOG="$tree/calls" STUB_BUILD_SAW="$tree/saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-test \
    docker run --rm -v "$tree/src:/src:ro" nixos/nix nix build --no-link --print-out-paths path:. \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" <<< /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-test
  diff - "$tree/saw/marker" <<< committed
  diff - "$tree/calls" << CALLS
["docker","run","--rm","-v","$tree/src:/src:ro","nixos/nix","nix","build","--no-link","--print-out-paths","path:."]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_edits_the_named_file_before_it_copies_the_build_mount() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/src"
  echo committed > "$tree/src/marker"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_LOG="$tree/calls" STUB_BUILD_SAW="$tree/saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-test \
    STUB_EDIT_DURING_BUILD="$tree/src/marker" \
    docker run --rm -v "$tree/src:/src:ro" nixos/nix nix build --no-link --print-out-paths path:. \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/saw/marker" <<< edited
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_a_build_with_the_named_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/src"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_LOG="$tree/calls" STUB_BUILD_SAW="$tree/saw" \
    STUB_BUILD_ERROR="error: builder for '/nix/store/x.drv' failed with exit code 1" \
    docker run --rm -v "$tree/src:/src:ro" nixos/nix nix build --no-link --print-out-paths path:. \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "error: builder for '/nix/store/x.drv' failed with exit code 1"
  [ -d "$tree/saw" ] || { echo "the failed build did not copy its mount" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_answers_a_copy_with_nothing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_LOG="$tree/calls" \
    docker run --rm nixos/nix nix copy --to ssh://root@geoffcloud /nix/store/x \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["docker","run","--rm","nixos/nix","nix","copy","--to","ssh://root@geoffcloud","/nix/store/x"]
CALLS
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_a_copy_with_the_named_error_and_exit_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_LOG="$tree/calls" \
    STUB_COPY_ERROR="error: cannot connect to 'root@geoffcloud'" \
    docker run --rm nixos/nix nix copy --to ssh://root@geoffcloud /nix/store/x \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "error: cannot connect to 'root@geoffcloud'"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_any_other_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_LOG="$tree/calls" docker ps -a \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: ps -a'
  diff - "$tree/calls" <<< '["docker","ps","-a"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_hands_a_logged_call_to_the_real_docker_which_fails_with_exit_1_without_a_daemon_at_its_socket() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/home"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" STUB_LOG="$tree/calls" \
    STUB_DOCKER_PASS=1 DOCKER_HOST="unix://$tree/docker.sock" \
    docker run --rm nixos/nix nix build --no-link --print-out-paths path:. \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  printf 'docker: Cannot connect to the Docker daemon at unix://%s/docker.sock. Is the docker daemon running?\n\nRun '"'"'docker run --help'"'"' for more information\n' "$tree" > "$tree/err-docker-28"
  printf 'failed to connect to the docker API at unix://%s/docker.sock; check if the path is correct and if the daemon is running: dial unix %s/docker.sock: connect: no such file or directory\n' "$tree" "$tree" > "$tree/err-docker-29"
  cmp -s "$tree/err-docker-28" "$tree/err" || cmp -s "$tree/err-docker-29" "$tree/err" ||
    { cat "$tree/err"; echo "exit $status; not docker 28's or 29's missing-socket error" >&2; exit 1; }
  diff - "$tree/calls" << 'CALLS'
["docker","run","--rm","nixos/nix","nix","build","--no-link","--print-out-paths","path:."]
CALLS
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# With no DOCKER_HOST the real docker would reach the machine's daemon; a broken guard
# here runs only `docker version`, which pulls nothing.
it_never_hands_a_call_to_the_real_docker_without_a_DOCKER_HOST() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/home"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" STUB_LOG="$tree/calls" STUB_DOCKER_PASS=1 \
    docker version > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: version (DOCKER_HOST=)'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_never_hands_a_call_to_the_real_docker_for_a_socket_outside_the_case_tree() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/home"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" STUB_LOG="$tree/calls" STUB_DOCKER_PASS=1 \
    DOCKER_HOST=unix:///var/run/docker.sock docker version > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: version (DOCKER_HOST=unix:///var/run/docker.sock)'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# The `..` climbs out of the case tree to a socket path under its parent that does not
# exist, so even a broken guard would reach no daemon.
it_never_hands_a_call_to_the_real_docker_for_a_socket_that_climbs_out_of_the_case_tree() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/home"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" STUB_LOG="$tree/calls" STUB_DOCKER_PASS=1 \
    DOCKER_HOST="unix://$tree/../$(basename "$tree")-outside/docker.sock" docker version \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: version (DOCKER_HOST=unix://$tree/../$(basename "$tree")-outside/docker.sock)"
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_hands_a_call_to_the_real_docker_with_the_socket_path_normalised() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/home" "$tree/sub"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" STUB_LOG="$tree/calls" STUB_DOCKER_PASS=1 \
    DOCKER_HOST="unix://$tree/sub/../docker.sock" docker version --format '{{.Client.Version}}' \
    > "$tree/out" 2> "$tree/err" || status=$?

  grep -qF "unix://$tree/docker.sock" "$tree/err" || { cat "$tree/err"; echo "the real docker did not get the normalised socket" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_hands_a_call_to_the_real_docker_for_a_tcp_host() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/home"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" STUB_LOG="$tree/calls" STUB_DOCKER_PASS=1 \
    DOCKER_HOST=tcp://127.0.0.1:1 docker version > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'unexpected: version (DOCKER_HOST=tcp://127.0.0.1:1)'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_hands_a_call_to_the_system_docker_not_one_on_the_callers_PATH() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  mkdir "$tree/bin" "$tree/fake" "$tree/home"
  printf '#!/usr/bin/env bash\necho fake docker\n' > "$tree/fake/docker"
  chmod +x "$tree/fake/docker"
  PATH="$tree/fake:$PATH" create_stub_nix_docker "$tree/bin"

  env -i PATH="$tree/bin:$tree/fake:/usr/bin:/bin" HOME="$tree/home" STUB_LOG="$tree/calls" \
    STUB_DOCKER_PASS=1 DOCKER_HOST="unix://$tree/docker.sock" docker version --format '{{.Client.Version}}' \
    > "$tree/out" 2> "$tree/err" || status=$?

  grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' "$tree/out" || { cat "$tree/out"; echo "not the real docker's client version" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin"
  create_stub_nix_docker "$tree/bin"
}

run_cases
