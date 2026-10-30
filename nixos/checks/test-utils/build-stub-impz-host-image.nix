# A stand-in imp-host image for the preview-image unit under real Podman: busybox, whose command
# only sleeps, with a stand-in impz and curl in /usr/local/bin. It returns { archive, ref, impz, curl }:
# the image as a docker save archive for `podman load`, the name Podman gives the loaded image,
# and the impz and curl stand-ins themselves, which nixos/checks/test-utils-check.nix tests.
#
# impz finds its token as the real one does: IMP_TOKEN, or else the file impz/token under
# XDG_CONFIG_HOME, or under HOME's .config, or under the passwd home's .config when HOME is unset.
# A HOME that is set but empty makes that path relative, so from the exec's working directory, /,
# it is /.config/impz/token. The image's /root/.config/impz/token links to /var/lib/imp/token, as
# the real image's does. When the token it finds differs from the file at $IMPD_TOKEN_FILE
# (default /var/lib/imp/token), which stands for the token impd loaded, or when it finds none, it
# fails as impz fails a call that impd refuses with 401. Otherwise it answers `image ls --json`,
# `image add <ref> --name <name> --json` and `image pin <name>` from $IMPD_STATE/images.json
# (default /var/lib/stub-impd), as nixos/checks/test-utils/build-stub-imp-host-podman.nix does, and
# records each call's argv as one JSON line in $IMPD_STATE/calls. Any other call fails with
# "unexpected: impz <argv>" and status 97. curl answers only
# `curl -sS --max-time 5 http://127.0.0.1:7070/health`, with impd's ready /health body.
#
# What it assumes of impz, from zgeoff/impz at the flake's imp input
# (packages/cli/src/config/cli-config.ts and packages/cli/src/config/host-store.ts): with no
# IMP_URL, IMP_HOST or saved host, impz takes IMP_TOKEN, or else reads the token file in
# XDG_CONFIG_HOME ?? join(HOME ?? homedir(), '.config'), under impz/; it sends no token when the
# file is missing, and impd answers that call with 401 (packages/daemon/src/identity/auth/
# authenticate.ts). The messages and the JSON are the podman stand-in's.
{ pkgs }:
let
  impz = pkgs.writeShellApplication {
    name = "impz";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      state=''${IMPD_STATE:-/var/lib/stub-impd}
      jq -cn '$ARGS.positional' --args -- "$@" >> "$state/calls"
      if [ -n "''${XDG_CONFIG_HOME+set}" ]; then
        config=$XDG_CONFIG_HOME
      elif [ -n "''${HOME+set}" ]; then
        config=''${HOME:+$HOME/}.config
      else
        config=/root/.config
      fi
      token=''${IMP_TOKEN:-}
      if [ -z "$token" ] && [ -e "$config/impz/token" ]; then
        token=$(cat "$config/impz/token")
      fi
      if [ -z "$token" ] || [ "$token" != "$(cat "''${IMPD_TOKEN_FILE:-/var/lib/imp/token}")" ]; then
        echo 'impz: unauthorized: set IMP_TOKEN to the token from <IMP_DATA_DIR>/token, or run impz login <url>' >&2
        exit 1
      fi
      if [ "$*" = "image ls --json" ]; then
        jq . "$state/images.json"
        exit 0
      fi
      if [ "$#" -eq 6 ] && [ "$1 $2" = "image add" ] && [ "$4" = --name ] && [ "$6" = --json ]; then
        image=$(jq --arg name "$5" --arg ref "$3" \
          '{id: $name, name: $name, ref: $ref, digest: "imp-build-stub", source: "oci", createdAt: "2026-01-01T00:00:00.000Z", sizeBytes: 0, pinned: (map(select(.name == $name) | .pinned == true) | any)}' \
          "$state/images.json")
        jq --argjson image "$image" '[.[] | select(.name != $image.name)] + [$image]' "$state/images.json" > "$state/images.json.new"
        mv "$state/images.json.new" "$state/images.json"
        jq . <<< "$image"
        exit 0
      fi
      if [ "$#" -eq 3 ] && [ "$1 $2" = "image pin" ]; then
        if ! jq -e --arg name "$3" 'any(.[]; .name == $name)' "$state/images.json" > /dev/null; then
          echo "impz: NOT_FOUND: image $3 not found" >&2
          exit 1
        fi
        jq --arg name "$3" 'map(if .name == $name then .pinned = true else . end)' "$state/images.json" > "$state/images.json.new"
        mv "$state/images.json.new" "$state/images.json"
        exit 0
      fi
      echo "unexpected: impz $*" >&2
      exit 97
    '';
  };
  curl = pkgs.writeShellApplication {
    name = "curl";
    text = ''
      if [ "$*" != "-sS --max-time 5 http://127.0.0.1:7070/health" ]; then
        echo "unexpected: curl $*" >&2
        exit 97
      fi
      printf '{"status":"ok","ready":true,"warnings":[]}'
    '';
  };
  tools = pkgs.runCommand "stub-impz-host-tools" { } ''
    mkdir -p $out/usr/local/bin
    ln -s ${pkgs.lib.getExe impz} $out/usr/local/bin/impz
    ln -s ${pkgs.lib.getExe curl} $out/usr/local/bin/curl
  '';
  archive = pkgs.dockerTools.buildImage {
    name = "stub-impz-host";
    tag = "local";
    copyToRoot = pkgs.buildEnv {
      name = "stub-impz-host-root";
      paths = [
        pkgs.busybox
        tools
      ];
      pathsToLink = [
        "/bin"
        "/usr/local/bin"
      ];
    };
    # real files, not links into the store, so the container can write impd's state
    extraCommands = ''
      mkdir -m 1777 tmp
      mkdir -p etc root/.config/impz var/lib/imp var/lib/stub-impd
      echo 'root:x:0:0:root:/root:/bin/sh' > etc/passwd
      echo 'root:x:0:' > etc/group
      echo imp_fixture_root > var/lib/imp/token
      ln -s ../../../var/lib/imp/token root/.config/impz/token
      echo '[]' > var/lib/stub-impd/images.json
    '';
    config = {
      Env = [ "PATH=/usr/local/bin:/bin" ];
      Cmd = [
        "sleep"
        "infinity"
      ];
    };
  };
in
{
  inherit archive;
  ref = "localhost/stub-impz-host:local";
  impz = pkgs.lib.getExe impz;
  curl = pkgs.lib.getExe curl;
}
