# A stand-in imp-host image for the impd-restore rehearsal: busybox, whose command only sleeps,
# with an imp-docker-proxy that only opens the socket imp's module waits for, an `imp info` that
# prints only its version line, and a /tmp, where copy-impd-db-host.sh makes its work
# directory. Given a tag, it returns { layout, ref }: the image as an OCI layout, and the reference geoffcloud would pin it
# by, ghcr.io/zgeoff/imp-host:<tag>@<digest>, whose digest is the layout's manifest digest, the
# one a registry serves it under once skopeo copies it with --preserve-digests. Reading that
# digest at evaluation is import from derivation.
#
# What it assumes of the real image, which nixos/checks/test-utils-check.nix pins to the
# flake's imp input: imp's module runs the proxy as /usr/local/bin/imp-docker-proxy in the same
# image, and waits for the socket /run/imp-docker/docker.sock; it runs imp-host from the image's
# own command; and `imp info` prints each line as its label padded to 12 characters, then the
# value, with the version first. The real one prints more lines; copy-impd-db-host.sh reads
# only the version.
{ pkgs }:
tag:
let
  proxy = pkgs.writeTextFile {
    name = "imp-docker-proxy-standin";
    destination = "/usr/local/bin/imp-docker-proxy";
    executable = true;
    text = ''
      #!/bin/sh
      exec ${pkgs.socat}/bin/socat UNIX-LISTEN:/run/imp-docker/docker.sock,fork EXEC:/bin/true
    '';
  };
  imp = pkgs.writeTextFile {
    name = "imp-standin";
    destination = "/usr/local/bin/imp";
    executable = true;
    text = ''
      #!/bin/sh
      if [ "$*" != info ]; then echo "unexpected: imp $*" >&2; exit 97; fi
      echo 'version     ${tag}'
    '';
  };
  image = pkgs.dockerTools.buildImage {
    name = "ghcr.io/zgeoff/imp-host";
    inherit tag;
    copyToRoot = pkgs.buildEnv {
      name = "imp-host-standin-root";
      paths = [
        pkgs.busybox
        proxy
        imp
      ];
      pathsToLink = [
        "/bin"
        "/usr/local/bin"
      ];
    };
    extraCommands = "mkdir -m 1777 tmp";
    config.Cmd = [
      "sleep"
      "infinity"
    ];
  };
  layout = pkgs.runCommand "imp-host-${tag}-oci" { nativeBuildInputs = [ pkgs.skopeo ]; } ''
    skopeo --insecure-policy copy docker-archive:${image} oci:$out:${tag}
  '';
in
{
  inherit layout;
  ref = "ghcr.io/zgeoff/imp-host:${tag}@${
    (builtins.head (pkgs.lib.importJSON "${layout}/index.json").manifests).digest
  }";
}
