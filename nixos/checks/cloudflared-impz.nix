# Reads the unit that carries impd's public MCP route (the registry's impd-mcp entry) through its
# Cloudflare tunnel, and the host's TLS front it replaced, from geoffcloud's own config: the unit
# runs cloudflared on the tunnel's token as a credential, waits for the file instead of failing the
# switch, and needs the tank/cloud bind that holds the file. The front serves no route, and its
# port 443 stays shut. Each case runs in a fresh directory, as a bats test.
# Run: bun run test:nixos cloudflared-impz
{
  nixpkgs,
  imp,
  geoffcloud,
}:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  unit = geoffcloud.config.systemd.services.cloudflared-impz;
  config = geoffcloud.config;

  cases = [
    {
      title = "it runs cloudflared on a token file that systemd loads as a credential";
      script = ''
        printf '%s\n' ${lib.escapeShellArg unit.serviceConfig.ExecStart} \
          | sed 's|^/nix/store/[a-z0-9]\{32\}-cloudflared-[^/]*/bin/cloudflared|cloudflared|' > actual

        diff -u - actual <<'EOF'
        cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:20241 run --token-file %d/tunnel-token
        EOF
        assert_equal ${lib.escapeShellArg unit.serviceConfig.LoadCredential} \
          'tunnel-token:/var/lib/imp-host/secrets/impd-mcp-tunnel-token'
      '';
    }
    {
      title = "it skips the unit until the token file exists, and refuses it without the secrets bind";
      script = ''
        assert_equal ${lib.escapeShellArg unit.unitConfig.ConditionPathExists} \
          /var/lib/imp-host/secrets/impd-mcp-tunnel-token
        assert_equal ${lib.escapeShellArg (toString config.services.tank-cloud.requiredBy.cloudflared-impz)} \
          imp-host-secrets
      '';
    }
    {
      title = "it runs no TLS front and opens no public port 443";
      script = ''
        assert_equal ${lib.boolToString config.services.public-front.enable} false
        assert_equal ${lib.boolToString config.services.caddy.enable} false
        assert_equal ${lib.boolToString (builtins.elem 443 config.networking.firewall.allowedTCPPorts)} false
      '';
    }
  ];
in
pkgs.runCommand "cloudflared-impz-check"
  {
    nativeBuildInputs = [
      (pkgs.bats.withLibraries (p: [
        p.bats-support
        p.bats-assert
      ]))
      pkgs.diffutils
      pkgs.gnused
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    bats --timing --print-output-on-failure ${pkgs.writeText "cloudflared-impz.bats" (renderCases cases)}
    touch $out
  ''
