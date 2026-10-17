#!/usr/bin/env bash
# Runs a read-only Pulumi command, a preview or a drift check, and runs it again when it fails on
# an error that a later try can pass. The prod apply job's drift checks and its preview run
# through it; the apply never does, because a second apply is not the same as the first.
#
# An error a later try can pass is one of these, matched in the command's output:
# - a 5xx answer from the ACME server, such as Let's Encrypt's
#   `503 :: POST :: …/acme/new-acct :: urn:ietf:params:acme:error:rateLimited :: Service busy;
#   retry later.` while the acme provider refreshes the nixie certificate;
# - `Could not automatically download and install resource plugin`, a plugin download that failed,
#   such as on GitHub's API rate limit.
# A 429 from the ACME server is a real rate limit, which lasts hours, so it fails at once.
#
# It runs <command> in <dir> (-C, default the current one) up to RETRY_ATTEMPTS times (default
# 3), and pauses RETRY_DELAY seconds (default 60) after each failed try it repeats, with a line on
# stderr that names the try. It exits 0 on the first try that passes, and with the last try's
# status when a try fails on any other error or the last try fails. Without --out, the command's
# stdout and stderr both pass to stdout as they come. With --out, each try writes its stdout to
# <file> afresh, so the file holds the last try's, and its stderr passes to stderr. A bad option
# or count, or no command, is a usage error (exit 2).
#
#   [RETRY_ATTEMPTS=<n>] [RETRY_DELAY=<seconds>] \
#     bash scripts/retry-transient-pulumi.sh [-C <dir>] [--out <file>] <command…>
set -euo pipefail

usage() {
  echo "usage: retry-transient-pulumi.sh [-C <dir>] [--out <file>] <command…>" >&2
  exit 2
}

dir=.
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C | --out)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then usage; fi
      if [ "$1" = -C ]; then dir="$2"; else out="$2"; fi
      shift 2
      ;;
    *) break ;;
  esac
done
if [ "$#" -eq 0 ]; then usage; fi
attempts="${RETRY_ATTEMPTS:-3}"
delay="${RETRY_DELAY:-60}"
if ! [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || ! [[ "$delay" =~ ^[0-9]+$ ]]; then usage; fi

transient='acme: error: 5[0-9][0-9] :: |Could not automatically download and install resource plugin'

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
cd "$dir"
attempt=1
while :; do
  set +e
  if [ -n "$out" ]; then
    "$@" 2>&1 > "$out" | tee "$log" >&2
    status="${PIPESTATUS[0]}"
  else
    "$@" 2>&1 | tee "$log"
    status="${PIPESTATUS[0]}"
  fi
  set -e
  if [ "$status" = 0 ]; then exit 0; fi
  if [ -n "$out" ]; then cat "$out" >> "$log"; fi
  if [ "$attempt" -ge "$attempts" ] || ! grep -qE "$transient" "$log"; then exit "$status"; fi
  echo "retry-transient-pulumi: try $attempt of $attempts failed (exit $status) on an error a later try can pass; trying again in ${delay}s" >&2
  sleep "$delay"
  attempt=$((attempt + 1))
done
