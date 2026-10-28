# A stand-in podman for the preview-image script (nixos/modules/preview-image.sh), the host build
# lag check (nixos/modules/host-build-lag.sh) and the agent image build
# (nixos/modules/agent-image-build.sh): it answers their impd calls through
# `podman exec imp-host impz` from a state directory, $IMPD_STATE, and records each call's argv as
# one JSON line in $IMPD_STATE/calls.
#
#   PODMAN=<this> IMPD_STATE=/tmp/impd preview-image
#
# The state directory holds:
#   - images.json, impd's images as `impz image ls --json` prints them: an array of objects;
#   - unreachable, optional: a count of calls still to fail, each as podman fails an exec while
#     the imp-host container does not exist, which the stand-in counts down;
#   - add-error, optional: a message the next `image add` fails with, as impz fails a call;
#   - version, optional: the imp version that `impz info` prints;
#   - container, optional: a directory that stands for the imp-host container's filesystem.
#
# `exec imp-host impz image ls --json` prints images.json, pretty-printed. `exec imp-host impz
# image add <ref> --name <name> --json` points <name> at <ref> in images.json, in place of any
# image of that name and with that image's pin, and prints the image. `exec imp-host impz image pin
# <name>` pins the image of that name and prints nothing, or fails with "impz: NOT_FOUND: image <name> not
# found" when images.json holds none. `exec imp-host impz info`, with a version file, prints
# the first line of `impz info`, the version, its label padded to 12 characters, and no other line.
# `cp imp-host:<path> <dest>` copies container/<path> to <dest> with its mode and prints nothing,
# or fails with 'Error: "<path>" could not be found on container imp-host: no such file or
# directory' when container/<path> is not a file.
# Any other call fails with "unexpected: <argv>" and status 97. Without $IMPD_STATE it exits 2.
#
# What it assumes of podman and impd, from zgeoff/impz at the flake's imp input
# (packages/cli/src/commands/image.ts, packages/cli/src/run-action.ts and
# packages/daemon/src/images/create-image-writer.ts): `impz image ls --json` and `impz image add
# --json` print JSON.stringify(value, null, 2) of an image list and of one image, with the fields
# id, name, ref, digest, source, createdAt, sizeBytes and pinned; impz prints a failure as one line,
# `impz: <message>`, and exits 1; an add under a name that exists points the name at the new image
# and keeps the name's pin (packages/daemon/src/platform/db/images.ts). podman prints
# 'Error: no container with name or ID "<name>" found: no such container' and exits 125 for an
# exec in a container that does not exist, and 'Error: "<path>" could not be found on container
# <name>: no such file or directory' and exits 125 for a cp of a path the container lacks (checked
# against podman 5). The id, digest, time and size the stand-in writes are its own, not impd's.
# nixos/checks/test-utils-check.nix tests it.
{ pkgs }:
pkgs.lib.getExe (
  pkgs.writeShellApplication {
    name = "podman-answering-impz";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      if [ -z "''${IMPD_STATE:-}" ]; then
        echo "podman-answering-impz: set IMPD_STATE to the directory that holds impd's images" >&2
        exit 2
      fi
      jq -cn '$ARGS.positional' --args -- "$@" >> "$IMPD_STATE/calls"
      if [ "$#" -ge 3 ] && [ "$1 $2 $3" = "exec imp-host impz" ] && [ -s "$IMPD_STATE/unreachable" ]; then
        left=$(cat "$IMPD_STATE/unreachable")
        if [ "$left" -gt 0 ]; then
          echo $((left - 1)) > "$IMPD_STATE/unreachable"
          echo 'Error: no container with name or ID "imp-host" found: no such container' >&2
          exit 125
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
        image=$(jq --argjson image "$image" '$image + {pinned: (map(select(.name == $image.name) | .pinned == true) | any)}' "$IMPD_STATE/images.json")
        jq --argjson image "$image" '[.[] | select(.name != $image.name)] + [$image]' "$IMPD_STATE/images.json" > "$IMPD_STATE/images.json.new"
        mv "$IMPD_STATE/images.json.new" "$IMPD_STATE/images.json"
        jq . <<< "$image"
        exit 0
      fi
      if [ "$#" -eq 6 ] && [ "$1 $2 $3 $4 $5" = "exec imp-host impz image pin" ]; then
        if ! jq -e --arg name "$6" 'any(.[]; .name == $name)' "$IMPD_STATE/images.json" > /dev/null; then
          echo "impz: NOT_FOUND: image $6 not found" >&2
          exit 1
        fi
        jq --arg name "$6" 'map(if .name == $name then .pinned = true else . end)' "$IMPD_STATE/images.json" > "$IMPD_STATE/images.json.new"
        mv "$IMPD_STATE/images.json.new" "$IMPD_STATE/images.json"
        exit 0
      fi
      if [ "$#" -eq 3 ] && [ "$1" = cp ] && [ "''${2#imp-host:/}" != "$2" ]; then
        path="''${2#imp-host:}"
        if [ ! -f "$IMPD_STATE/container$path" ]; then
          echo "Error: \"$path\" could not be found on container imp-host: no such file or directory" >&2
          exit 125
        fi
        cp --preserve=mode "$IMPD_STATE/container$path" "$3"
        exit 0
      fi
      echo "unexpected: $*" >&2
      exit 97
    '';
  }
)
