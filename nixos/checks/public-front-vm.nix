# services.public-front on a booted VM, serving the registry's impd-mcp route
# (packages/topology/exposure.json) with its own hostname, upstream and paths, so the check proves
# the paths the host's front passes and the 404 it gives every other path. Two settings differ from
# the host: Caddy's local CA issues the certificate, since the VM reaches no ACME server, and the
# rate limit is low enough for a case to pass it. The upstream is impd's public listener stand-in,
# test-utils/run-stub-mcp-upstream.py, on the route's loopback address; its log shows each request
# that reached it, as it arrived.
# It needs KVM: run `bun run test:nixos public-front-vm`.
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  route = builtins.head (
    builtins.filter (entry: entry.name == "impd-mcp") (import ../exposure.nix).entries
  );
  upstreamPort = pkgs.lib.last (pkgs.lib.splitString ":" route.upstream);
  events = 20;
in
pkgs.testers.runNixOSTest {
  name = "public-front-vm";
  nodes.machine = {
    imports = [ ../modules/public-front.nix ];
    services.public-front = {
      enable = true;
      routes = [ { inherit (route) hostname upstream paths; } ];
      rateLimit = {
        inherit events;
        window = "10m";
      };
      issuer = "internal";
    };
    networking.hosts."127.0.0.1" = [ route.hostname ];
    networking.hosts."::1" = [ route.hostname ];
    systemd.services.stub-mcp-upstream = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        RuntimeDirectory = "stub-mcp-upstream";
        ExecStart = "${pkgs.python3}/bin/python3 ${./test-utils/run-stub-mcp-upstream.py} ${upstreamPort} /run/stub-mcp-upstream/requests /run/stub-mcp-upstream/release";
      };
    };
    environment.systemPackages = [ pkgs.jq ];
  };

  testScript = ''
    import json

    hostname = "${route.hostname}"
    paths = json.loads('${builtins.toJSON route.paths}')
    requests = "/run/stub-mcp-upstream/requests"


    def curl(family, target, *options):
        """requests target from the front over HTTPS from the loopback address of the IP family
        (-4 or -6), with the front's own CA, and returns the status and body"""
        out = machine.succeed(
            f"curl -s {family} --cacert /tmp/front-ca.crt -w '\\n%{{http_code}}' {' '.join(options)} 'https://{hostname}{target}'"
        )
        body, _, status = out.rpartition("\n")
        return status, body


    def read_requests():
        return [json.loads(line) for line in machine.succeed(f"cat {requests} 2>/dev/null || true").splitlines()]


    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("caddy.service")
    machine.wait_for_unit("stub-mcp-upstream.service")
    machine.wait_for_open_port(443)
    machine.wait_for_open_port(${upstreamPort})
    machine.wait_until_succeeds(
        "cp \"$(find /var/lib/caddy -path '*/pki/authorities/local/root.crt')\" /tmp/front-ca.crt", timeout=60
    )
    machine.wait_until_succeeds(f"curl -s -4 --cacert /tmp/front-ca.crt -o /dev/null https://{hostname}/", timeout=60)


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it listens on TCP 443 alone, with no port 80 and no HTTP/3 on UDP 443"):
        tcp = machine.succeed("ss -Hltnp | grep caddy | awk '{print $4}' | sort").split()
        udp = machine.succeed("ss -Hlunp | grep caddy || true").strip()

        assert tcp == ["*:443"], f"caddy listens on {tcp}"
        assert udp == "", f"caddy listens on UDP: {udp}"


    with subtest("it passes each of the route's paths to the upstream as sent, with its Host and Authorization"):
        machine.succeed(f"rm -f {requests}")
        answers = [
            curl("-4", path, "-X POST", "-H 'Authorization: Bearer example-token'", "--data '{}'") for path in paths
        ]

        assert answers == [("200", f"POST {path}") for path in paths], answers
        assert read_requests() == [
            {"method": "POST", "path": path, "host": hostname, "authorization": "Bearer example-token"}
            for path in paths
        ], read_requests()


    with subtest("it answers 404 itself for any other path, and the upstream never sees it"):
        machine.succeed(f"rm -f {requests}")
        others = [
            "/",
            "/health",
            "/rpc/imps/list",
            "/ui/",
            "/exec",
            "/MCP",
            "/mcp/",
            "/mcpx",
            "/login/x",
            "/.well-known/oauth-protected-resource/other",
            "/rpc/../mcp",
            "/mcp/../rpc/imps/list",
        ]
        answers = [curl("-4", path, "--path-as-is", "-H 'Authorization: Bearer example-token'") for path in others]

        assert answers == [("404", "")] * len(others), answers
        assert read_requests() == [], read_requests()


    with subtest("it streams an event to the client before the upstream ends the stream"):
        machine.succeed(f"rm -f {requests} /run/stub-mcp-upstream/release /tmp/stream")
        machine.succeed(f"curl -s -4 -N --cacert /tmp/front-ca.crt -o /tmp/stream https://{hostname}/mcp >/dev/null 2>&1 &")
        machine.wait_until_succeeds("grep -qx 'data: first' /tmp/stream", timeout=10)
        held = machine.succeed("cat /tmp/stream")
        machine.succeed("touch /run/stub-mcp-upstream/release")
        machine.wait_until_succeeds("grep -qx 'data: second' /tmp/stream", timeout=10)

        assert held == "data: first\n\n", repr(held)
        assert machine.succeed("cat /tmp/stream") == "data: first\n\ndata: second\n\n"


    with subtest("it answers 429 to a client address past its limit, and still serves another address"):
        machine.succeed(f"rm -f {requests}")
        limited = [curl("-6", "/login") for _ in range(${toString events} + 1)]
        other = curl("-4", "/login")

        assert limited[:-1] == [("200", "GET /login")] * ${toString events}, limited
        assert limited[-1][0] == "429", limited[-1]
        assert other == ("200", "GET /login"), other
        assert len(read_requests()) == ${toString events} + 1, read_requests()
  '';
}
