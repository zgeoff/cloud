# services.atc-daemon on a booted VM, with the pinned atc release, run as the host runs it: the
# gateway token is a root-only file that systemd's LoadCredential reads. The atc-daemon check only
# evaluates the module, so a token file that atc refuses at start, as atc 7.4.0 refuses one that
# another user owns, passes it; here the daemon must open its port. The imp target names a loopback
# impd that the VM never runs, because the daemon reaches impd only when a session starts.
# It needs KVM: run `bun run test:nixos atc-daemon-vm`.
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  atc = pkgs.callPackage ../packages/atc.nix { };
  secrets = "/var/lib/atc-daemon-secrets";
  port = 8415;
  # 32 bytes or more, as atc needs; fixed values, never a real token
  gatewayToken = "gateway-fixture-bearer-0123456789abcdef-0123456789abcdef";
  rotatedToken = "gateway-fixture-rotated-0123456789abcdef-0123456789abcdef";
in
pkgs.testers.runNixOSTest {
  name = "atc-daemon-vm";
  nodes.machine = {
    imports = [ ../modules/atc-daemon.nix ];
    services.atc-daemon = {
      enable = true;
      package = atc;
      listen = "127.0.0.1:${toString port}";
      tokenFile = "${secrets}/gateway-token";
      impTokenFile = "${secrets}/imp-token";
      targets.fixture = {
        provider = "imp";
        url = "http://127.0.0.1:7070";
        tokenFile = "/run/credentials/atc-daemon.service/imp-token";
        impPrefix = "harness-";
      };
      defaultTarget = "fixture";
      principals.fixture-client.targets = [ "fixture" ];
    };
    # the token files as the host's install scripts leave them: root's, mode 0400, in a directory
    # of mode 0700, written before the daemon's first start
    systemd.services.fixture-atc-tokens = {
      requiredBy = [ "atc-daemon.service" ];
      before = [ "atc-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        umask 077
        mkdir -p ${secrets}
        printf '%s\n' ${gatewayToken} > ${secrets}/gateway-token
        printf '%s\n' imp-fixture-bearer > ${secrets}/imp-token
        chmod 0400 ${secrets}/gateway-token ${secrets}/imp-token
      '';
    };
  };

  testScript = ''
    secrets = "${secrets}"
    staged = "/run/atc-daemon/gateway-token"


    def assert_serving():
        """the daemon listens, which atc does only after it loads its token file, and systemd
        never restarted it"""
        machine.wait_for_open_port(${toString port}, timeout=60)
        state = machine.succeed("systemctl show -P ActiveState,NRestarts atc-daemon.service").split()
        assert state == ["active", "0"], f"atc-daemon.service is {state}"


    machine.wait_for_unit("multi-user.target")


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it runs the daemon on a copy of the gateway token that the daemon's user owns, mode 0600, on tmpfs"):
        assert_serving()

        found = machine.succeed(f"stat -c '%n %U %G %a' /run/atc-daemon {staged}")
        assert found == f"/run/atc-daemon atc atc 700\n{staged} atc atc 600\n", found
        fs = machine.succeed(f"findmnt -n -o FSTYPE -T {staged}").strip()
        assert fs == "tmpfs", f"{staged} is on {fs}"
        machine.succeed(f"cmp {staged} {secrets}/gateway-token")


    with subtest("it reads a rewritten gateway token after a restart"):
        machine.succeed(f"umask 077 && printf '%s\\n' ${rotatedToken} > {secrets}/gateway-token")
        machine.succeed("systemctl restart atc-daemon.service")

        assert_serving()
        assert machine.succeed(f"cat {staged}") == "${rotatedToken}\n"


    with subtest("it removes the copy of the gateway token when the daemon stops"):
        machine.succeed("systemctl stop atc-daemon.service")

        machine.fail("test -e /run/atc-daemon")
  '';
}
