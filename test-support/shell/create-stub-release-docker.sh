# shellcheck shell=bash
# create_stub_release_docker <bin>: writes <bin>/docker, a stand-in for the docker CLI calls that
# bump-release.sh and pin-imp.sh make. It logs each call's argv as a JSON line to STUB_TREE/calls,
# then:
#
# - `buildx imagetools inspect <ref> --format {{json .Manifest}}` prints
#   STUB_TREE/images/<ref with each "/" as "_">.json, the manifest descriptor a test writes there.
#   A ref the tree lacks answers as buildx 0.37.1 does: "ERROR: <ref>: not found" on stderr and
#   exit 1, checked against the real buildx on 2026-10-13.
# - `run --rm -v <dir>:/src -w /src <image> sh -c <command>`, where the command runs
#   `nix … flake lock`, copies STUB_TREE/flake.lock over <dir>/flake.lock, as the real lock writes
#   it, or, with STUB_LOCK_ERROR set, prints it on stderr and exits 1 with the lock unchanged, as
#   nix exits 1 on a failed lock (nix 2.35.2 in the pinned image, checked on 2026-10-13 with an
#   input whose commit does not exist).
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_release_docker() {
  local bin="$1"
  cat > "$bin/docker" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' docker "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
case "$*" in
  "buildx imagetools inspect "*" --format {{json .Manifest}}")
    file="$STUB_TREE/images/${4//\//_}.json"
    if [ ! -f "$file" ]; then echo "ERROR: $4: not found" >&2; exit 1; fi
    cat "$file"
    ;;
  "run --rm -v "*":/src -w /src "*" sh -c "*"flake lock"*)
    if [ -n "${STUB_LOCK_ERROR:-}" ]; then echo "$STUB_LOCK_ERROR" >&2; exit 1; fi
    cp "$STUB_TREE/flake.lock" "${4%:/src}/flake.lock"
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/docker"
}
