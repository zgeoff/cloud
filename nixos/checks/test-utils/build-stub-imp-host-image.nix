# A stand-in imp-host image for the impd-restore rehearsal: busybox, whose command only sleeps,
# with an imp-docker-proxy that only opens the socket imp's module waits for. Given a tag, it
# returns { layout, ref }: the image as an OCI layout, and the reference geoffcloud would pin it
# by, ghcr.io/zgeoff/imp-host:<tag>@<digest>, whose digest is the layout's manifest digest, the
# one a registry serves it under once skopeo copies it with --preserve-digests. Reading that
# digest at evaluation is import from derivation.
#
# What it assumes of the real image, which nixos/checks/test-utils-check.nix pins to the
# flake's imp input: imp's module runs the proxy as /usr/local/bin/imp-docker-proxy in the same
# image, and waits for the socket /run/imp-docker/docker.sock; it runs imp-host from the image's
# own command.
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
  image = pkgs.dockerTools.buildImage {
    name = "ghcr.io/zgeoff/imp-host";
    inherit tag;
    copyToRoot = pkgs.buildEnv {
      name = "imp-host-standin-root";
      paths = [
        pkgs.busybox
        proxy
      ];
      pathsToLink = [
        "/bin"
        "/usr/local/bin"
      ];
    };
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
