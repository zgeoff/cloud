# A stand-in curl for the impd-local-health check: it records its argv as one JSON line in
# $CURL_LOG, then answers as curl does when no answer comes within --max-time. The probe's one
# call, `curl -s -o <file> -w %{http_code} --max-time <seconds> <url>`, prints 000, writes no
# file and exits 28, curl's status for a timeout, at once: it never connects, so a check reads
# the timeout curl was given without waiting it out. Any other call is recorded too, and fails
# with "unexpected: <argv>" and status 97. Without $CURL_LOG it exits 2.
#
#   CURL=<this> CURL_LOG=$PWD/curl.log impd-local-health
#
# What it assumes of curl and of nixos/modules/impd-local-health.sh, which
# nixos/checks/test-utils-check.nix pins: curl given that call prints 000, writes no file and
# exits 28 when the server never answers; the probe makes that call through $CURL.
# nixos/checks/test-utils-check.nix tests it.
{ pkgs }:
pkgs.writeShellScript "curl-timing-out" ''
  set -euo pipefail
  if [ -z "''${CURL_LOG:-}" ]; then
    echo "curl-timing-out: set CURL_LOG to the file that records each call" >&2
    exit 2
  fi
  ${pkgs.jq}/bin/jq -cn '$ARGS.positional' --args -- "$@" >> "$CURL_LOG"
  case "$#:''${1-}:''${2-}:''${4-}:''${5-}:''${6-}" in
    "8:-s:-o:-w:%{http_code}:--max-time")
      printf 000
      exit 28
      ;;
    *)
      echo "unexpected: $*" >&2
      exit 97
      ;;
  esac
''
