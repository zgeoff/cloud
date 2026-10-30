# services.preview's preview-image unit on a booted VM with real Podman, cold-started as a switch
# that recreates imp-host starts it: the unit starts when imp-host's unit does, before Podman has
# created imp-host's container and mounted its root filesystem. The container is the stand-in
# imp-host image (test-utils/build-stub-impz-host-image.nix), whose impz finds impd's token through
# HOME as the real impz does. Podman sets an exec's HOME from the container's /etc/passwd, which
# it reads through the root filesystem's mount as the caller sees it, so a unit with a mount
# namespace of its own from before that mount gets no HOME, and impz no token. imp-host is a unit
# that waits 5 s before its `podman run`, so the unit's start always comes before the mount. The
# preview service itself never starts: its secret files do not exist.
# It needs KVM: run `bun run test:nixos preview-image-vm`.
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  stubImage = import ./test-utils/build-stub-impz-host-image.nix { inherit pkgs; };
  ref = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
in
pkgs.testers.runNixOSTest {
  name = "preview-image-vm";
  nodes.machine =
    { config, ... }:
    let
      podman = lib.getExe config.virtualisation.podman.package;
    in
    {
      imports = [ ../modules/preview.nix ];
      virtualisation.memorySize = 1536;
      virtualisation.podman.enable = true;
      networking.nftables = {
        enable = true;
        flushRuleset = false;
      };
      services.preview = {
        enable = true;
        linkListen = "100.64.0.1:8417";
        webhookListen = "100.64.0.1:8418";
        baseURL = "http://cloudhost:8417";
        repos = [ "acme/greenhouse" ];
        impdURL = "http://127.0.0.1:7070";
        impDomain = "imps.example.org";
        impRegistryImage = ref;
        webhookSecretFile = "/run/fixture/webhook-secret";
        githubAppClientIDFile = "/run/fixture/github-app-client-id";
        githubAppKeyFile = "/run/fixture/github-app-key";
        impTokenFile = "/run/fixture/imp-token";
      };
      # as imp's module runs it: Type=exec, so the unit counts as started once podman run is
      # exec'd, and the units that follow it start before the container exists
      systemd.services.imp-host = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "exec";
          ExecStartPre = [
            "${podman} load -q -i ${stubImage.archive}"
            "-${podman} rm -f imp-host"
          ];
          ExecStart = pkgs.writeShellScript "imp-host" ''
            ${pkgs.coreutils}/bin/sleep 5
            exec ${podman} run --rm --name imp-host --network none ${stubImage.ref}
          '';
          ExecStop = "${podman} stop -t 5 imp-host";
        };
      };
      # 15 tries of 2 s outlast the 5 s before the container exists, and a first start that fails
      # them restarts within the test's wait
      systemd.services.preview-image.environment.PREVIEW_IMAGE_WAIT_TRIES = "15";
    };

  testScript = ''
    import json


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it adds and pins the image on its first start, when it starts before the imp-host container exists"):
        machine.wait_for_unit("preview-image.service", timeout=300)
        unit = machine.succeed("systemctl show -p ActiveState -p Result -p NRestarts preview-image.service").split()
        images = json.loads(machine.succeed("podman exec imp-host cat /var/lib/stub-impd/images.json"))
        journal = machine.succeed("journalctl -b -u preview-image.service -o cat | grep '^preview-image: '").splitlines()
        # which of Podman's two refusals the tries meet before the container runs depends on timing
        tries = [line.split(": ", 2)[2] for line in journal if line.startswith("preview-image: try ")]

        assert sorted(unit) == ["ActiveState=active", "NRestarts=0", "Result=success"], unit
        assert [(image["name"], image["ref"], image["pinned"]) for image in images] == [("pv-base", "${ref}", True)], images
        assert tries != [], "the unit's first try found imp-host's container running"
        assert set(tries) <= {
            'Error: no container with name or ID "imp-host" found: no such container',
            "Error: can only create exec sessions on running containers: container state improper",
        }, tries
        assert [line for line in journal if not line.startswith("preview-image: try ")] == [
            "preview-image: adding ${ref} to impd as pv-base",
            "preview-image: pinning pv-base",
            "preview-image: impd holds pv-base at ${ref}, pinned",
        ], journal
  '';
}
