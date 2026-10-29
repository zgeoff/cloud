# A stand-in sleep for the impd-restore rehearsals, the preview-image script and the agent image
# build: it records its argv as one JSON line in $SLEEP_LOG and returns at once, as the real sleep
# returns once its pause is over. A call with one duration, a number of seconds such as `sleep 1`,
# exits 0 with no output, as sleep does. Any other call is recorded too, and fails with "unexpected: <argv>" and
# status 97. Without $SLEEP_LOG it exits 2. Each script counts its pauses rather than reading a
# clock, so the stand-in needs no time source: the pauses it records are the wait.
#
#   IMPD_START_SLEEP=<this> SLEEP_LOG=/tmp/sleep.log restore-impd-db ...
#
# What it assumes of sleep and of restore-impd-db (nixos/packages/impd-db-tools), which
# nixos/checks/test-utils-check.nix pins: sleep given one number of seconds prints nothing and
# exits 0; the script's start loop pauses through $IMPD_START_SLEEP with `1`, once for each of
# its IMPD_START_WAIT_SECONDS tries; preview-image (nixos/modules/preview-image.sh) pauses through
# $SLEEP with `2` between its tries, and agent-image-build (nixos/modules/agent-image-build.sh)
# with `5`. nixos/checks/test-utils-check.nix tests it.
{ pkgs }:
pkgs.lib.getExe (
  pkgs.writeShellApplication {
    name = "sleep-returning-at-once";
    text = ''
      if [ -z "''${SLEEP_LOG:-}" ]; then
        echo "sleep-returning-at-once: set SLEEP_LOG to the file that records each call" >&2
        exit 2
      fi
      ${pkgs.jq}/bin/jq -cn '$ARGS.positional' --args -- "$@" >> "$SLEEP_LOG"
      if [ "$#" -eq 1 ] && [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        exit 0
      fi
      echo "unexpected: $*" >&2
      exit 97
    '';
  }
)
