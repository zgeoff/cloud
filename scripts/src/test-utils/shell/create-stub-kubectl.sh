# shellcheck shell=bash
# create_stub_kubectl <bin> <store> <log>: writes <bin>/kubectl, a stand-in for kubectl against an
# API server that holds Lease objects (coordination.k8s.io/v1), as hold-prod-lock.sh calls it.
# Each Lease is the file <store>/<namespace>/<name>.json. Each call logs its argv as one JSON line
# to <log> and holds <store>/.lock with flock, so two callers at once see one server.
#
# It answers three calls, each after a leading --request-timeout=<duration>:
#   --namespace <ns> get lease <name> --output json  prints the Lease, or NotFound
#   create --filename -                              stores the Lease on stdin at resourceVersion
#                                                    1, or AlreadyExists
#   replace --filename -                             stores the Lease on stdin at the next
#                                                    resourceVersion when its resourceVersion is
#                                                    the stored one, or Conflict, or NotFound
# A file <store>/race.json stands for another writer: the next replace first stores it as a new
# version of its Lease, then removes it, so that replace meets a Conflict. A file <store>/forbidden
# stands for an account without access to Leases: each get answers Forbidden for the user that the
# file names.
#
# The messages and exit status 1 match kubectl 1.34's for each server answer; they come from
# kubectl's error printer (k8s.io/kubectl/pkg/cmd/util/helpers.go, "Error from server (<reason>):
# error when <verb> \"STDIN\": …" for a file from stdin) and the API server's status messages
# (k8s.io/apimachinery/pkg/api/errors), checked against kubectl's source on 2026-10-21. The success
# lines are kubectl's `<resource>.<group>/<name> created|replaced`. Any other call exits 97 with
# "unexpected: <argv>" on stderr.
create_stub_kubectl() {
  local bin="$1" store="$2" log="$3"
  {
    echo '#!/usr/bin/env bash'
    printf 'store=%q\nlog=%q\n' "$store" "$log"
    cat << 'STUB'
set -euo pipefail
mkdir -p "$store"
printf '%s\0' kubectl "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$log"
exec 9> "$store/.lock"
flock 9
if [[ "${1:-}" != --request-timeout=* ]]; then
  echo "unexpected: $*" >&2
  exit 97
fi
shift
case "$*" in
  "--namespace "*" get lease "*" --output json")
    namespace="$2" name="$5"
    if [ -f "$store/forbidden" ]; then
      echo "Error from server (Forbidden): leases.coordination.k8s.io \"$name\" is forbidden: User \"$(cat "$store/forbidden")\" cannot get resource \"leases\" in API group \"coordination.k8s.io\" in the namespace \"$namespace\"" >&2
      exit 1
    fi
    if [ ! -f "$store/$namespace/$name.json" ]; then
      echo "Error from server (NotFound): leases.coordination.k8s.io \"$name\" not found" >&2
      exit 1
    fi
    cat "$store/$namespace/$name.json"
    ;;
  "create --filename -")
    lease="$(cat)"
    namespace="$(jq -r .metadata.namespace <<< "$lease")" name="$(jq -r .metadata.name <<< "$lease")"
    if [ -f "$store/$namespace/$name.json" ]; then
      echo "Error from server (AlreadyExists): error when creating \"STDIN\": leases.coordination.k8s.io \"$name\" already exists" >&2
      exit 1
    fi
    mkdir -p "$store/$namespace"
    jq '.metadata.resourceVersion = "1"' <<< "$lease" > "$store/$namespace/$name.json"
    echo "lease.coordination.k8s.io/$name created"
    ;;
  "replace --filename -")
    lease="$(cat)"
    namespace="$(jq -r .metadata.namespace <<< "$lease")" name="$(jq -r .metadata.name <<< "$lease")"
    file="$store/$namespace/$name.json"
    if [ ! -f "$file" ]; then
      echo "Error from server (NotFound): error when replacing \"STDIN\": leases.coordination.k8s.io \"$name\" not found" >&2
      exit 1
    fi
    if [ -f "$store/race.json" ]; then
      jq --arg version "$(($(jq -r .metadata.resourceVersion "$file") + 1))" \
        '.metadata.resourceVersion = $version' "$store/race.json" > "$file.next"
      mv "$file.next" "$file"
      rm "$store/race.json"
    fi
    stored="$(jq -r .metadata.resourceVersion "$file")"
    if [ "$(jq -r '.metadata.resourceVersion // ""' <<< "$lease")" != "$stored" ]; then
      echo "Error from server (Conflict): error when replacing \"STDIN\": Operation cannot be fulfilled on leases.coordination.k8s.io \"$name\": the object has been modified; please apply your changes to the latest version and try again" >&2
      exit 1
    fi
    jq --arg version "$((stored + 1))" '.metadata.resourceVersion = $version' <<< "$lease" > "$file.next"
    mv "$file.next" "$file"
    echo "lease.coordination.k8s.io/$name replaced"
    ;;
  *)
    echo "unexpected: --request-timeout=… $*" >&2
    exit 97
    ;;
esac
STUB
  } > "$bin/kubectl"
  chmod +x "$bin/kubectl"
}
