# services.onepassword-connect-relay on a booted VM, through a switch that moves the relay from
# Docker's bridge to Podman's, as the host's move of imp-host from Docker to Podman does. The boot
# config listens on docker0's 172.17.0.1, and its podman specialisation on podman0's 10.88.0.1.
# Each bridge has a network namespace on it that stands for a container, and Python's http.server
# on the VM's loopback stands for the Connect Service the relay dials. A request through the relay
# before the switch leaves the proxy running, holding the socket it was started with, as an imp's
# requests leave it on the host.
# It needs KVM: run `bun run test:nixos onepassword-connect-relay-vm`.
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  port = 18081;
  targetPort = 8000;
in
pkgs.testers.runNixOSTest {
  name = "onepassword-connect-relay-vm";
  nodes.machine = {
    imports = [ ../modules/onepassword-connect-relay.nix ];
    networking.nftables = {
      enable = true;
      flushRuleset = false;
    };
    services.onepassword-connect-relay = {
      enable = true;
      interface = "docker0";
      address = "172.17.0.1";
      inherit port;
      allowedSubnet = "172.17.0.0/16";
      target = "127.0.0.1:${toString targetPort}";
    };
    specialisation.podman.configuration.services.onepassword-connect-relay = {
      interface = lib.mkForce "podman0";
      address = lib.mkForce "10.88.0.1";
      allowedSubnet = lib.mkForce "10.88.0.0/16";
    };
    systemd.services.stub-connect = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server --bind 127.0.0.1 --directory /var/empty ${toString targetPort}";
    };
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    def add_bridge(bridge, address, container, veth, container_address):
        """makes the bridge with the host's address on it, and a network namespace that stands for
        a container on it, joined to the bridge by the veth"""
        machine.succeed(
            f"ip link add {bridge} type bridge",
            f"ip addr add {address}/16 dev {bridge}",
            f"ip link set {bridge} up",
            f"ip netns add {container}",
            f"ip link add {veth} type veth peer name eth0 netns {container}",
            f"ip link set {veth} master {bridge} up",
            f"ip -n {container} addr add {container_address}/16 dev eth0",
            f"ip -n {container} link set eth0 up",
            f"ip -n {container} link set lo up",
        )


    def read_listeners():
        return sorted(machine.succeed("ss -Hltn sport = :${toString port} | awk '{print $4}'").split())


    def request(container, address):
        return machine.succeed(
            f"ip netns exec {container} curl -sS -m 5 -o /dev/null -w '%{{http_code}}' http://{address}:${toString port}/"
        )


    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("stub-connect.service")
    machine.wait_for_open_port(${toString targetPort})
    add_bridge("docker0", "172.17.0.1", "docker-container", "veth-docker", "172.17.0.2")
    add_bridge("podman0", "10.88.0.1", "podman-container", "veth-podman", "10.88.0.2")


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it relays a request from a container on docker0 to the target, and keeps the proxy running"):
        status = request("docker-container", "172.17.0.1")
        proxy = machine.succeed("systemctl show -p ActiveState --value onepassword-connect-relay.service").strip()

        assert status == "200", f"the relay answered {status}"
        assert proxy == "active", f"the proxy is {proxy}"
        assert read_listeners() == ["172.17.0.1:${toString port}"], read_listeners()


    with subtest("it listens on podman0's address alone after the switch, and relays a request from a container there"):
        machine.succeed("/run/current-system/specialisation/podman/bin/switch-to-configuration test")
        machine.wait_for_unit("onepassword-connect-relay.socket")

        assert read_listeners() == ["10.88.0.1:${toString port}"], read_listeners()
        status = request("podman-container", "10.88.0.1")
        assert status == "200", f"the relay answered {status}"
  '';
}
