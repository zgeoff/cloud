# A stand-in bun for the agent image build (nixos/modules/agent-image-build.sh): it answers
# `bun scripts/build-agent-image.ts <commit>` as the build script does, from a state directory,
# $BUILD_STATE, and records each such call as one JSON line in $BUILD_STATE/calls: its argv, its
# working directory, the IMP_URL and IMP_TOKEN it got, and the path of the impz that its PATH
# resolves, or null.
#
#   BUN=<this> BUILD_STATE=/tmp/build agent-image-build
#
# The state directory holds:
#   - stdout, optional: the text the call prints on stdout, such as the build's result line;
#   - status, optional: the exit status of the call, 0 without the file.
#
# The build script takes [--keep] and one commit on main (scripts/parse-build-agent-image-args.ts);
# the stand-in answers the form without --keep only. Any other call fails with
# "unexpected: <argv>" and status 97. Without $BUILD_STATE it exits 2.
# nixos/checks/test-utils-check.nix tests it.
{ pkgs }:
pkgs.lib.getExe (
  pkgs.writeShellApplication {
    name = "bun-answering-build-agent-image";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      if [ -z "''${BUILD_STATE:-}" ]; then
        echo "bun-answering-build-agent-image: set BUILD_STATE to the directory that holds the build's answer" >&2
        exit 2
      fi
      if [ "$#" -ne 2 ] || [ "$1" != scripts/build-agent-image.ts ] || [ "''${2#-}" != "$2" ]; then
        echo "unexpected: $*" >&2
        exit 97
      fi
      impz=$(command -v impz || true)
      jq -cn --arg cwd "$PWD" --arg impz "$impz" \
        '{argv: $ARGS.positional, cwd: $cwd, impURL: env.IMP_URL, impToken: env.IMP_TOKEN, impz: (if $impz == "" then null else $impz end)}' \
        --args -- "$@" >> "$BUILD_STATE/calls"
      if [ -f "$BUILD_STATE/stdout" ]; then
        cat "$BUILD_STATE/stdout"
      fi
      if [ -f "$BUILD_STATE/status" ]; then
        exit "$(cat "$BUILD_STATE/status")"
      fi
    '';
  }
)
