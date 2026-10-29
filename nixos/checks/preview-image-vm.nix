# services.preview's preview-image unit on a booted VM, cold-started as a switch that recreates
# imp-host starts it: imp-host's container is missing at first, then impd reports not ready on
# /health, then impd refuses impz calls for more tries than the unit's first start made before it
# waited for /health (60). impd stands behind the stand-in podman
# (test-utils/build-stub-imp-host-podman.nix), the unit's pauses go through the stand-in sleep
# (test-utils/build-stub-sleep.nix), and imp-host is a unit that only sleeps. The preview service
# itself never starts: its secret files do not exist.
# It needs KVM: run `bun run test:nixos preview-image-vm`.
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  stubImpHostPodman = import ./test-utils/build-stub-imp-host-podman.nix { inherit pkgs; };
  stubSleep = import ./test-utils/build-stub-sleep.nix { inherit pkgs; };
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
      SLEEP = stubSleep;
      SLEEP_LOG = "/var/lib/stub-impd/sleep.log";
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/stub-impd 0755 root root -"
      "f /var/lib/stub-impd/images.json 0644 root root - []"
      "f /var/lib/stub-impd/unreachable 0644 root root - 1"
      "f /var/lib/stub-impd/starting 0644 root root - 3"
      "f /var/lib/stub-impd/unauthorized 0644 root root - 61"
      "d /var/lib/stub-impd/container/var/lib/imp 0755 root root -"
      "f /var/lib/stub-impd/container/var/lib/imp/token 0600 root root - imp_fixture_root"
      "d /var/lib/stub-impd/container/root/.config/impz 0700 root root -"
      "L /var/lib/stub-impd/container/root/.config/impz/token - - - - ../../../var/lib/imp/token"
      "d /var/lib/stub-impd/container/proc 0755 root root -"
      "f /var/lib/stub-impd/container/proc/stat 0644 root root - btime 1793300000"
    ];
  };

  testScript = ''
    import json


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it adds and pins the image on its first start, waiting out the missing container, impd's start and impd's refusals"):
        machine.wait_for_unit("preview-image.service")
        unit = machine.succeed("systemctl show -p ActiveState -p Result -p NRestarts preview-image.service").split()
        calls = [json.loads(line) for line in machine.succeed("cat /var/lib/stub-impd/calls").splitlines()]
        images = json.loads(machine.succeed("cat /var/lib/stub-impd/images.json"))
        journal = machine.succeed("journalctl -b -u preview-image.service -o cat | grep '^preview-image: '").splitlines()
        inode = machine.succeed("stat -c %i /var/lib/stub-impd/container/var/lib/imp/token").strip()
        modified = machine.succeed("date -u -d @$(stat -c %Y /var/lib/stub-impd/container/var/lib/imp/token) +%Y-%m-%dT%H:%M:%SZ").strip()
        health = ["exec", "imp-host", "curl", "-sS", "--max-time", "5", "http://127.0.0.1:7070/health"]
        ls = ["exec", "imp-host", "impz", "image", "ls", "--json"]
        facts = ["exec", "-i", "imp-host", "sh", "-s", "--", "/root/.config/impz/token", "/proc"]

        assert sorted(unit) == ["ActiveState=active", "NRestarts=0", "Result=success"], unit
        assert calls == [health] * 5 + [ls, facts] * 61 + [
            ls,
            ["exec", "imp-host", "impz", "image", "add", "${ref}", "--name", "pv-base", "--json"],
            ["exec", "imp-host", "impz", "image", "pin", "pv-base"],
        ], calls
        assert [(image["name"], image["ref"], image["pinned"]) for image in images] == [("pv-base", "${ref}", True)], images
        assert journal == [
            'preview-image: try 1: Error: no container with name or ID "imp-host" found: no such container',
            'preview-image: try 2: impd is not ready: /health answered {"status":"ok","ready":false,"warnings":[]}',
            f"preview-image: try 5: impz: unauthorized: set IMP_TOKEN to the token from <IMP_DATA_DIR>/token, or run impz login <url>; impz's token file: inode {inode}, modified {modified}",
            "preview-image: adding ${ref} to impd as pv-base",
            "preview-image: pinning pv-base",
            "preview-image: impd holds pv-base at ${ref}, pinned",
        ], journal
  '';
}
