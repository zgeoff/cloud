# shellcheck shell=bash
# create_stub_publish_docker <bin>: writes <bin>/docker, a stand-in for the docker CLI calls that
# publish-atc-gateway-images.sh makes. It logs each call's argv as a JSON line to STUB_TREE/calls.
# Its state is files named for a ref with each "/" and ":" as "_": STUB_TREE/registry/<ref> for a
# published ref, STUB_TREE/digests/<ref> for the digest the registry gives a ref on its push, and
# STUB_TREE/built/<ref> for a local image, which the stand-in writes itself.
#
# - `login <registry> -u <user> --password-stdin` writes stdin to STUB_TREE/password, so a test
#   reads the token the caller sent without it ever reaching argv, and prints "Login Succeeded".
# - `build --build-arg <arg> -t <ref> <context>` records the ref as built and writes the sorted
#   names in <context> to STUB_TREE/contexts/<ref>. It prints none of BuildKit's progress, which
#   the caller does not read.
# - `manifest inspect <ref>` prints the ref's registry file. A ref the registry lacks answers
#   "manifest unknown" on stderr and exit 1; with STUB_TREE/registry-error present, every lookup
#   prints that file's text on stderr and exits 1 instead, as for a registry that cannot answer.
# - `push <ref>` prints "The push refers to repository [<name>]" and publishes the ref with its
#   digest. A ref never built prints "tag does not exist: <ref>" on stderr and exits 1.
# - `inspect --format {{index .RepoDigests 0}} <ref>` prints "<name>@<digest>" for a ref it
#   pushed. A ref never built prints "Error: no such object: <ref>" on stderr and exits 1.
# - any other call, a push with no digest file, and an inspect of a ref built but never pushed,
#   which has no repo digest, end with exit 97 and "unexpected: <argv>" on stderr.
#
# The messages and exit codes are docker 29.7.2's, checked on 2026-10-14: `manifest inspect` of a
# missing ghcr.io tag, and `push` and `inspect` of a ref with no local image.
create_stub_publish_docker() {
  local bin="$1"
  cat > "$bin/docker" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' docker "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
# key <ref>: the ref as a file name
key() {
  local ref="${1//\//_}"
  echo "${ref//:/_}"
}
mkdir -p "$STUB_TREE/registry" "$STUB_TREE/built" "$STUB_TREE/contexts"
if [ "$#" = 5 ] && [ "$1" = login ] && [ "$3" = -u ] && [ "$5" = --password-stdin ]; then
  cat > "$STUB_TREE/password"
  echo "Login Succeeded"
elif [ "$#" = 6 ] && [ "$1" = build ] && [ "$2" = --build-arg ] && [ "$4" = -t ]; then
  touch "$STUB_TREE/built/$(key "$5")"
  ls -A "$6" | LC_ALL=C sort > "$STUB_TREE/contexts/$(key "$5")"
elif [ "$#" = 3 ] && [ "$1" = manifest ] && [ "$2" = inspect ]; then
  if [ -f "$STUB_TREE/registry-error" ]; then
    cat "$STUB_TREE/registry-error" >&2
    exit 1
  fi
  if [ ! -f "$STUB_TREE/registry/$(key "$3")" ]; then
    echo "manifest unknown" >&2
    exit 1
  fi
  cat "$STUB_TREE/registry/$(key "$3")"
elif [ "$#" = 2 ] && [ "$1" = push ] && [ -f "$STUB_TREE/digests/$(key "$2")" ]; then
  echo "The push refers to repository [${2%:*}]"
  if [ ! -f "$STUB_TREE/built/$(key "$2")" ]; then
    echo "tag does not exist: $2" >&2
    exit 1
  fi
  jq -cn --arg digest "$(cat "$STUB_TREE/digests/$(key "$2")")" '{digest: $digest}' > "$STUB_TREE/registry/$(key "$2")"
elif [ "$#" = 4 ] && [ "$1" = inspect ] && [ "$2" = --format ] && [ "$3" = '{{index .RepoDigests 0}}' ] &&
  { [ ! -f "$STUB_TREE/built/$(key "$4")" ] || [ -f "$STUB_TREE/registry/$(key "$4")" ]; }; then
  if [ ! -f "$STUB_TREE/built/$(key "$4")" ]; then
    echo "Error: no such object: $4" >&2
    exit 1
  fi
  echo "${4%:*}@$(jq -r .digest "$STUB_TREE/registry/$(key "$4")")"
else
  echo "unexpected: $*" >&2
  exit 97
fi
STUB
  chmod +x "$bin/docker"
}
