# services.agent-image-build on a booted VM, through a switch that recreates imp-host while the
# build's timer fires, as a host switch that changes imp does. imp-host is a unit that only sleeps,
# and the stand-in podman of test-utils/build-stub-imp-host-podman.nix answers for the container:
# imp-host's start marks the container missing before it starts the build and lets it answer once
# the unit runs. The specialisation's imp-host differs from the boot config's, so the switch
# restarts it, and its start starts the build mid-recreate, in place of the timer. In the recreate
# specialisation, impd holds the image of the origin's newest commit on images/agent; in the remove
# specialisation, impd holds none, and the container is gone once impd has listed its images. The
# build's origin is a local repository.
# It needs KVM: run `bun run test:nixos agent-image-build-switch-vm`.
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  stubImpHostPodman = import ./test-utils/build-stub-imp-host-podman.nix { inherit pkgs; };
  impdState = "/var/lib/stub-impd";
in
pkgs.testers.runNixOSTest {
  name = "agent-image-build-switch-vm";
  nodes.machine = {
    imports = [ ../modules/agent-image-build.nix ];
    services.agent-image-build = {
      enable = true;
      repoURL = "/var/lib/fixture-origin";
      impdURL = "http://127.0.0.1:7070";
      impTokenFile = "/etc/agent-image-build/imp-token";
    };
    environment.etc."agent-image-build/imp-token".text = "imp_fixture_build_token";
    systemd.services.agent-image-build.environment = {
      PODMAN = lib.mkForce stubImpHostPodman;
      IMPD_STATE = impdState;
    };
    # the test starts each build itself
    systemd.timers.agent-image-build.wantedBy = lib.mkForce [ ];
    systemd.services.imp-host = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
    };
    specialisation.recreate.configuration.systemd.services.imp-host.serviceConfig = {
      ExecStartPre = [
        "${pkgs.bash}/bin/bash -c 'echo 1000 > ${impdState}/unreachable'"
        "${pkgs.systemd}/bin/systemctl start --no-block agent-image-build.service"
        "${pkgs.coreutils}/bin/sleep 15"
      ];
      ExecStart = lib.mkForce "${pkgs.bash}/bin/bash -c 'echo 0 > ${impdState}/unreachable; exec ${pkgs.coreutils}/bin/sleep infinity'";
    };
    specialisation.remove.configuration.systemd.services.imp-host.serviceConfig = {
      ExecStartPre = [
        "${pkgs.bash}/bin/bash -c 'echo [] > ${impdState}/images.json; rm -f ${impdState}/container-ids'"
        "${pkgs.systemd}/bin/systemctl start --no-block agent-image-build.service"
        "${pkgs.coreutils}/bin/sleep 15"
      ];
      ExecStart = lib.mkForce "${pkgs.bash}/bin/bash -c 'echo c0ffee02 > ${impdState}/container-ids; exec ${pkgs.coreutils}/bin/sleep infinity'";
    };
    systemd.tmpfiles.rules = [ "d ${impdState} 0755 root root -" ];
    environment.systemPackages = [
      pkgs.git
      pkgs.jq
    ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("imp-host.service")
    machine.succeed(
        "git init -q -b main /var/lib/fixture-origin",
        "git -C /var/lib/fixture-origin config maintenance.auto false",
        "mkdir -p /var/lib/fixture-origin/images/agent",
        "echo 'ARG ATC_VERSION=1.0.0' > /var/lib/fixture-origin/images/agent/Dockerfile",
        "git -C /var/lib/fixture-origin add -A",
        "git -C /var/lib/fixture-origin -c user.name='Fixture Author' -c user.email=author@example.com commit -q -m 'pin atc 1.0.0'",
    )
    pin = machine.succeed("git -C /var/lib/fixture-origin rev-parse HEAD").strip()
    image = "agent-" + machine.succeed("git -C /var/lib/fixture-origin rev-parse --short HEAD").strip()
    machine.succeed(
        f"jq -n --arg name {image} '[{{id: \"img-1\", name: $name, ref: \"\", digest: \"imp-build-aa\", source: \"build\", createdAt: \"2026-01-01T00:00:00.000Z\", sizeBytes: 0, pinned: true}}]' > ${impdState}/images.json"
    )


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it finishes the switch with no failed unit when the build starts while the switch recreates imp-host"):
        status, out = machine.execute("/run/current-system/specialisation/recreate/bin/switch-to-configuration test 2>&1")
        machine.wait_until_succeeds("test \"$(systemctl show -p ActiveState --value agent-image-build.service)\" = inactive", timeout=120)
        build = machine.succeed("systemctl show -p Result -p ExecMainStatus agent-image-build.service").split()
        lines = machine.succeed("journalctl -b -u agent-image-build.service -o cat | grep '^agent-image-build: '").splitlines()

        assert status == 0, f"switch-to-configuration exited {status}: {out}"
        assert sorted(build) == ["ExecMainStatus=0", "Result=success"], build
        assert lines == [
            'agent-image-build: waiting for impd, try 1: Error: no container with name or ID "imp-host" found: no such container',
            f"agent-image-build: impd holds {image}, built from {pin}; nothing to build",
        ], lines


    with subtest("it finishes the switch with no failed unit when imp-host loses its container after impd listed its images"):
        cursor = machine.succeed("journalctl -n 1 --show-cursor -o cat").splitlines()[-1].removeprefix("-- cursor: ")
        status, out = machine.execute("/run/booted-system/specialisation/remove/bin/switch-to-configuration test 2>&1")
        machine.wait_until_succeeds("test \"$(systemctl show -p ActiveState --value agent-image-build.service)\" = inactive", timeout=120)
        build = machine.succeed("systemctl show -p Result -p ExecMainStatus agent-image-build.service").split()
        lines = machine.succeed(f"journalctl --after-cursor='{cursor}' -u agent-image-build.service -o cat | grep '^agent-image-build: '").splitlines()

        assert status == 0, f"switch-to-configuration exited {status}: {out}"
        assert sorted(build) == ["ExecMainStatus=0", "Result=success"], build
        assert lines == [
            f"agent-image-build: imp-host went from the container that listed impd's images to none before the build of {image} from {pin}; the next run builds {image} again",
        ], lines
        machine.fail("test -e /var/lib/agent-image-build/failed")
  '';
}
