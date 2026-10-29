# services.preview's preview-image unit on a booted VM, whose first start finds impd refusing its
# calls for longer than the unit's wait. impd stands behind the stand-in podman
# (test-utils/build-stub-imp-host-podman.nix), whose unauthorized count outlasts the 3 tries that
# PREVIEW_IMAGE_WAIT_TRIES gives each start, and imp-host is a unit that only sleeps. The preview
# service itself never starts: its secret files do not exist.
# It needs KVM: run `bun run test:nixos preview-image-vm`.
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  stubImpHostPodman = import ./test-utils/build-stub-imp-host-podman.nix { inherit pkgs; };
  ref = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
in
pkgs.testers.runNixOSTest {
  name = "preview-image-vm";
  nodes.machine = {
    imports = [ ../modules/preview.nix ];
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
    systemd.services.imp-host = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
    };
    systemd.services.preview-image.environment = {
      PODMAN = stubImpHostPodman;
      IMPD_STATE = "/var/lib/stub-impd";
      PREVIEW_IMAGE_WAIT_TRIES = "3";
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/stub-impd 0755 root root -"
      "f /var/lib/stub-impd/images.json 0644 root root - []"
      "f /var/lib/stub-impd/unauthorized 0644 root root - 4"
    ];
  };

  testScript = ''
    import json


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it adds and pins the image on the first boot, starting again once impd refused every try of its first start"):
        machine.wait_for_unit("preview-image.service")
        unit = machine.succeed("systemctl show -p ActiveState -p Result -p NRestarts preview-image.service").split()
        calls = [json.loads(line) for line in machine.succeed("cat /var/lib/stub-impd/calls").splitlines()]
        images = json.loads(machine.succeed("cat /var/lib/stub-impd/images.json"))
        failure = machine.succeed("journalctl -b -u preview-image.service -o cat | grep 'impd listed no images'").strip()

        assert sorted(unit) == ["ActiveState=active", "NRestarts=1", "Result=success"], unit
        assert calls == [["exec", "imp-host", "impz", "image", "ls", "--json"]] * 5 + [
            ["exec", "imp-host", "impz", "image", "add", "${ref}", "--name", "pv-base", "--json"],
            ["exec", "imp-host", "impz", "image", "pin", "pv-base"],
        ], calls
        assert [(image["name"], image["ref"], image["pinned"]) for image in images] == [("pv-base", "${ref}", True)], images
        assert failure == "preview-image: impd listed no images after 3 tries: impz: unauthorized: set IMP_TOKEN to the token from <IMP_DATA_DIR>/token, or run impz login <url>", failure
  '';
}
