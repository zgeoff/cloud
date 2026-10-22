#!/usr/bin/env bash
# The prod lock, which the scheduled drift check on the host and the Deploy prod job both take, so
# neither reads or writes the prod stack's state while the other does. It is the Lease
# kube-system/cloud-prod-state in k3s, which both reach: the host as root, and the job over the
# tailnet with the admin kubeconfig. kubectl reads the cluster from KUBECONFIG.
#
# `take` holds the lock for <holder>, such as `deploy-prod 1234`, for <lease> seconds. It creates
# the Lease, or replaces it when no one holds it, <holder> already holds it, or its holder's lease
# has run out, which is how a holder that never released it, such as a runner that died, lets go.
# Each replace carries the resourceVersion it read, so of two takers at once only one wins, and the
# other reads again. While another holder holds it, it says who and until when on stderr, and asks
# again every LOCK_WAIT_DELAY seconds (default 30). It exits 75 when the lock is still held after
# <wait> seconds.
#
# `release` clears the holder when <holder> holds the lock, and otherwise leaves the Lease as it is,
# so a release after a takeover never frees the new holder's lock.
#
# `check` exits 0 when the Lease names <holder> as its holder, and otherwise exits 3 and says who
# holds it. A lease that ran out still counts, because a taker always replaces the holder, so while
# the Lease names <holder> no one else has taken the lock.
#
# Each exits 1 with kubectl's error on any other answer from the API, and 2 on a usage error.
#
#   KUBECONFIG=<file> bash scripts/hold-prod-lock.sh take <holder> <lease seconds> <wait seconds>
#   KUBECONFIG=<file> bash scripts/hold-prod-lock.sh release <holder>
#   KUBECONFIG=<file> bash scripts/hold-prod-lock.sh check <holder>
set -euo pipefail

usage() {
  echo "usage: hold-prod-lock.sh take <holder> <lease seconds> <wait seconds> | release <holder> | check <holder>" >&2
  exit 2
}

case "${1:-}" in
  take) if [ "$#" -ne 4 ] || [[ ! "$3" =~ ^[1-9][0-9]*$ ]] || [[ ! "$4" =~ ^[0-9]+$ ]]; then usage; fi ;;
  release | check) if [ "$#" -ne 2 ]; then usage; fi ;;
  *) usage ;;
esac
if [ -z "$2" ]; then usage; fi
holder="$2"
delay="${LOCK_WAIT_DELAY:-30}"
namespace=kube-system
name=cloud-prod-state
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

kube() {
  kubectl --request-timeout=30s "$@" 2> "$err"
}

# read_lease: prints the Lease, or nothing when there is none
read_lease() {
  if kube --namespace "$namespace" get lease "$name" --output json; then return; fi
  if grep -q '^Error from server (NotFound)' "$err"; then return; fi
  fail
}

# fail: ends the run with kubectl's error
fail() {
  cat "$err" >&2
  exit 1
}

# write <verb> <lease>: creates or replaces the Lease; fails when another writer won the race
write() {
  if kube "$1" --filename - <<< "$2" > /dev/null; then return; fi
  if grep -qE '^Error from server \((AlreadyExists|Conflict|NotFound)\)' "$err"; then return 1; fi
  fail
}

to_time() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000000Z
}

take() {
  local lease_seconds="$1" wait="$2" start now lease current current_holder expires
  start="$(date -u +%s)"
  while :; do
    now="$(date -u +%s)"
    lease="$(jq -n --arg namespace "$namespace" --arg name "$name" --arg holder "$holder" \
      --argjson seconds "$lease_seconds" --arg now "$(to_time "$now")" \
      '{apiVersion: "coordination.k8s.io/v1", kind: "Lease",
        metadata: {namespace: $namespace, name: $name},
        spec: {holderIdentity: $holder, leaseDurationSeconds: $seconds, acquireTime: $now, renewTime: $now}}')"
    current="$(read_lease)"
    if [ -z "$current" ]; then
      if write create "$lease"; then break; fi
      continue
    fi
    current_holder="$(jq -r '.spec.holderIdentity // ""' <<< "$current")"
    expires=0
    if [ -n "$current_holder" ]; then
      expires=$(($(date -u -d "$(jq -r .spec.renewTime <<< "$current")" +%s) + $(jq -r .spec.leaseDurationSeconds <<< "$current")))
    fi
    if [ -z "$current_holder" ] || [ "$current_holder" = "$holder" ] || [ "$now" -ge "$expires" ]; then
      if [ -n "$current_holder" ] && [ "$current_holder" != "$holder" ]; then
        echo "hold-prod-lock: $current_holder let the prod lock run out at $(to_time "$expires"); taking it over" >&2
      fi
      if write replace "$(jq --argjson lease "$lease" '{apiVersion, kind, metadata, spec: $lease.spec}' <<< "$current")"; then break; fi
      continue
    fi
    if [ $((now - start)) -ge "$wait" ]; then
      echo "hold-prod-lock: $current_holder still holds the prod lock after ${wait}s" >&2
      exit 75
    fi
    echo "hold-prod-lock: $current_holder holds the prod lock until $(to_time "$expires"); asking again in ${delay}s" >&2
    sleep "$delay"
  done
  echo "hold-prod-lock: took the prod lock as $holder" >&2
}

release() {
  local current
  while :; do
    current="$(read_lease)"
    if [ -z "$current" ] || [ "$(jq -r '.spec.holderIdentity // ""' <<< "$current")" != "$holder" ]; then
      echo "hold-prod-lock: $holder does not hold the prod lock; leaving it" >&2
      return
    fi
    if write replace "$(jq '{apiVersion, kind, metadata, spec: (.spec | del(.holderIdentity))}' <<< "$current")"; then break; fi
  done
  echo "hold-prod-lock: released the prod lock as $holder" >&2
}

check() {
  local current current_holder='' expires
  current="$(read_lease)"
  if [ -n "$current" ]; then current_holder="$(jq -r '.spec.holderIdentity // ""' <<< "$current")"; fi
  if [ "$current_holder" != "$holder" ]; then
    echo "hold-prod-lock: $holder does not hold the prod lock; its holder is ${current_holder:-no one}" >&2
    exit 3
  fi
  expires=$(($(date -u -d "$(jq -r .spec.renewTime <<< "$current")" +%s) + $(jq -r .spec.leaseDurationSeconds <<< "$current")))
  if [ "$(date -u +%s)" -ge "$expires" ]; then
    echo "hold-prod-lock: $holder holds the prod lock; its lease ran out at $(to_time "$expires"), and no one took it over" >&2
    return
  fi
  echo "hold-prod-lock: $holder holds the prod lock until $(to_time "$expires")" >&2
}

case "$1" in
  take) take "$3" "$4" ;;
  release) release ;;
  check) check ;;
esac
