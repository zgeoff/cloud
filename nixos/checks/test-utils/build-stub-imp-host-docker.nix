# A stand-in docker for the preview-image script (nixos/modules/preview-image.sh) and the host build
# lag check (nixos/modules/host-build-lag.sh): it answers their impd calls through
# `docker exec imp-host impz` from a state directory, $IMPD_STATE, and records each call's argv as
# one JSON line in $IMPD_STATE/calls.
#
#   DOCKER=<this> IMPD_STATE=/tmp/impd preview-image
#
# The state directory holds:
#   - images.json, impd's images as `impz image ls --json` prints them: an array of objects;
#   - unreachable, optional: a count of calls still to fail, each as docker fails an exec while
#     the imp-host container does not exist, which the stand-in counts down;
#   - add-error, optional: a message the next `image add` fails with, as impz fails a call;
#   - version, optional: the imp version that `impz info` prints.
#
# `exec imp-host impz image ls --json` prints images.json, pretty-printed. `exec imp-host impz
# image add <ref> --name <name> --json` points <name> at <ref> in images.json, in place of any
# image of that name, and prints the image. `exec imp-host impz info`, with a version file, prints
# the first line of `impz info`, the version, its label padded to 12 characters, and no other line.
# Any other call fails with "unexpected: <argv>" and status 97. Without $IMPD_STATE it exits 2.
#
# What it assumes of docker and impd, from zgeoff/impz at the flake's imp input
# (packages/cli/src/commands/image.ts, packages/cli/src/run-action.ts and
# packages/daemon/src/images/create-image-writer.ts): `impz image ls --json` and `impz image add
# --json` print JSON.stringify(value, null, 2) of an image list and of one image, with the fields
# id, name, ref, digest, source, createdAt and sizeBytes; impz prints a failure as one line,
# `impz: <message>`, and exits 1; an add under a name that exists points the name at the new
# image. docker prints "Error response from daemon: No such container: <name>" and exits 1 for an
# exec in a container that does not exist. The id, digest, time and size the stand-in writes are
# its own, not impd's. nixos/checks/test-utils-check.nix tests it.
{ pkgs }:
pkgs.lib.getExe (
  pkgs.writeShellApplication {
    name = "docker-answering-impz";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      if [ -z "''${IMPD_STATE:-}" ]; then
        echo "docker-answering-impz: set IMPD_STATE to the directory that holds impd's images" >&2
        exit 2
      fi
      jq -cn '$ARGS.positional' --args -- "$@" >> "$IMPD_STATE/calls"
      if [ "$#" -ge 3 ] && [ "$1 $2 $3" = "exec imp-host impz" ] && [ -s "$IMPD_STATE/unreachable" ]; then
        left=$(cat "$IMPD_STATE/unreachable")
        if [ "$left" -gt 0 ]; then
          echo $((left - 1)) > "$IMPD_STATE/unreachable"
          echo "Error response from daemon: No such container: imp-host" >&2
          exit 1
        fi
      fi
      if [ "$*" = "exec imp-host impz image ls --json" ]; then
        jq . "$IMPD_STATE/images.json"
        exit 0
      fi
      if [ "$*" = "exec imp-host impz info" ] && [ -s "$IMPD_STATE/version" ]; then
        printf 'version     %s\n' "$(cat "$IMPD_STATE/version")"
        exit 0
      fi
      if [ "$#" -eq 9 ] && [ "$1 $2 $3 $4 $5" = "exec imp-host impz image add" ] &&
        [ "$7" = --name ] && [ "$9" = --json ]; then
        if [ -e "$IMPD_STATE/add-error" ]; then
          echo "impz: $(cat "$IMPD_STATE/add-error")" >&2
          rm "$IMPD_STATE/add-error"
          exit 1
        fi
        image=$(jq -n --arg name "$8" --arg ref "$6" --arg digest "imp-build-$(printf '%s' "$6" | sha256sum | cut -d' ' -f1)" \
          '{id: $name, name: $name, ref: $ref, digest: $digest, source: "oci", createdAt: "2026-01-01T00:00:00.000Z", sizeBytes: 0}')
        jq --argjson image "$image" '[.[] | select(.name != $image.name)] + [$image]' "$IMPD_STATE/images.json" > "$IMPD_STATE/images.json.new"
        mv "$IMPD_STATE/images.json.new" "$IMPD_STATE/images.json"
        jq . <<< "$image"
        exit 0
      fi
      echo "unexpected: $*" >&2
      exit 97
    '';
  }
)
