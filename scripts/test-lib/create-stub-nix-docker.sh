# shellcheck shell=bash
# create_stub_nix_docker <bin>: writes <bin>/docker, a stand-in for the docker CLI that
# switch-geoffcloud.sh runs the nixos/nix image with. It logs each call's argv as a JSON
# line to STUB_LOG, then:
#
# - a build (`run … build --no-link --print-out-paths …`) edits STUB_EDIT_DURING_BUILD
#   when set (so a build of the working tree would see the edit), copies its /src mount to
#   STUB_BUILD_SAW, then fails with STUB_BUILD_ERROR on stderr and nix's exit 1, or prints
#   STUB_BUILD_OUT;
# - a copy (`run … copy --to ssh://…`) prints nothing, or fails with STUB_COPY_ERROR and
#   exit 1;
# - with STUB_DOCKER_PASS=1 and DOCKER_HOST a unix:// socket whose normalised path
#   (realpath -m, so `..` and symlinks resolve first) lies inside the directory that holds
#   STUB_LOG (the case's tree), the call goes to the real docker after it is logged, with
#   DOCKER_HOST set to that normalised path,
#   so a case reaches a real failure such as a missing daemon socket. The real docker is
#   the one on the fixed system path (/usr/local/bin, /usr/bin, /bin) when the stand-in
#   is created, never one from the caller's PATH. With STUB_DOCKER_PASS=1 and any other
#   DOCKER_HOST, including none, which would reach the machine's daemon, the call ends
#   with exit 97;
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_nix_docker() {
  local bin="$1" real_docker
  real_docker="$(PATH=/usr/local/bin:/usr/bin:/bin command -v docker || true)"
  {
    printf '#!/usr/bin/env bash\nreal_docker=%q\n' "$real_docker"
    cat << 'STUB'
printf '%s\0' docker "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
if [ -n "${STUB_DOCKER_PASS:-}" ]; then
  socket=""
  if [[ "${DOCKER_HOST:-}" == unix://* ]]; then socket="$(realpath -m -- "${DOCKER_HOST#unix://}")"; fi
  case_tree="$(realpath -m -- "$(dirname "$STUB_LOG")")"
  if [ -n "$real_docker" ] && [ -n "$socket" ] && [[ "$socket" == "$case_tree/"* ]]; then
    DOCKER_HOST="unix://$socket" exec "$real_docker" "$@"
  fi
  echo "unexpected: $* (DOCKER_HOST=${DOCKER_HOST:-})" >&2
  exit 97
fi
case "$1 $*" in
  "run "*" build --no-link --print-out-paths "*)
    src=""
    for arg in "$@"; do
      case "$arg" in *":/src:ro") src="${arg%:/src:ro}" ;; esac
    done
    if [ -n "${STUB_EDIT_DURING_BUILD:-}" ]; then echo edited > "$STUB_EDIT_DURING_BUILD"; fi
    cp -R "$src" "$STUB_BUILD_SAW"
    if [ -n "${STUB_BUILD_ERROR:-}" ]; then echo "$STUB_BUILD_ERROR" >&2; exit 1; fi
    printf '%s\n' "$STUB_BUILD_OUT"
    ;;
  "run "*" copy --to ssh://"*)
    if [ -n "${STUB_COPY_ERROR:-}" ]; then echo "$STUB_COPY_ERROR" >&2; exit 1; fi
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  } > "$bin/docker"
  chmod +x "$bin/docker"
}
