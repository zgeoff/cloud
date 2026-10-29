# Evaluates services.onepassword-connect-relay apart from any host's config, beside imp's own
# module (the flake's pinned imp input), and checks the socket and the services it adds, the port it
# admits in inet cloud_host and opens on imp-host's bridge, and its assertion. Each case evaluates
# its own config through test-utils/build-module-system.nix and runs on its own, in a fresh
# directory, under test-support/shell/run-cases.sh, which reports each case and fails the check
# when any case fails.
# Run: bun run test:nixos onepassword-connect-relay
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };
  collectFailedAssertions = import ./test-utils/collect-failed-assertions.nix;
  # the relay's module beside imp's, whose IPv6 mode it asserts on
  relayModule = {
    imports = [
      ../modules/onepassword-connect-relay.nix
      imp.nixosModules.imp
    ];
  };

  cases = [
    {
      title = "it proxies the socket on the relay address to the target, hardened, and restarts the socket and the proxy at a switch that moves the address";
      script =
        let
          system = buildModuleSystem relayModule {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            services.onepassword-connect-relay = {
              enable = true;
              interface = "podman0";
              address = "10.88.0.1";
              port = 18081;
              allowedSubnet = "10.88.0.0/16";
              target = "10.43.82.198:8000";
            };
          };
          socket = system.config.systemd.sockets.onepassword-connect-relay;
          service = system.config.systemd.services.onepassword-connect-relay;
          listen = system.config.systemd.services.onepassword-connect-relay-listen;
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            socket = {
              wantedBy = [ "sockets.target" ];
              listenStreams = [ "10.88.0.1:18081" ];
              socketConfig.FreeBind = true;
            };
            partOf = [ "onepassword-connect-relay.socket" ];
            listen = {
              description = "the Connect relay's socket on its listen address";
              wantedBy = [ "multi-user.target" ];
              after = [ "onepassword-connect-relay.socket" ];
              restartTriggers = [ "10.88.0.1:18081" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${system.config.systemd.package}/bin/systemctl restart onepassword-connect-relay.socket";
              };
            };
            serviceConfig = {
              ExecStart = "${system.config.systemd.package}/lib/systemd/systemd-socket-proxyd 10.43.82.198:8000";
              DynamicUser = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              NoNewPrivileges = true;
              RestrictAddressFamilies = [
                "AF_INET"
                "AF_INET6"
                "AF_UNIX"
              ];
              CapabilityBoundingSet = "";
            };
          }}
          EOF
          jq -S . > actual <<'EOF'
          ${builtins.toJSON {
            socket = {
              inherit (socket) wantedBy listenStreams socketConfig;
            };
            inherit (service) partOf serviceConfig;
            listen = {
              inherit (listen)
                description
                wantedBy
                after
                restartTriggers
                serviceConfig
                ;
            };
          }}
          EOF

          assert_files_equal expected actual
        '';
    }
    {
      title = "it admits the podman0 subnet to the relay in the host table and opens its port on podman0";
      script =
        let
          system = buildModuleSystem relayModule {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            services.onepassword-connect-relay = {
              enable = true;
              interface = "podman0";
              address = "10.88.0.1";
              port = 18081;
              allowedSubnet = "10.88.0.0/16";
              target = "10.43.82.198:8000";
            };
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                {
                  port = 18081;
                  interface = "podman0";
                  sourceCIDR = "10.88.0.0/16";
                  destinationAddress = "10.88.0.1";
                }
              ]
            )
          } ${lib.escapeShellArg (builtins.toJSON system.config.networking.cloudHost.admissions)} "the cloud_host admissions"
          assert_equals '[18081]' ${lib.escapeShellArg (builtins.toJSON system.config.networking.firewall.interfaces.podman0.allowedTCPPorts)} "the ports nixos-fw opens on podman0"
        '';
    }
    {
      title = "it admits nothing and opens no port when the relay is off, with no interface given";
      script =
        let
          system = buildModuleSystem relayModule {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
          };
        in
        ''
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON system.config.networking.cloudHost.admissions)} "the cloud_host admissions"
          assert_equals '{}' ${lib.escapeShellArg (builtins.toJSON system.config.networking.firewall.interfaces)} "the interfaces nixos-fw opens ports on"
        '';
    }
    {
      title = "it fails no assertion for a valid config";
      script =
        let
          system = buildModuleSystem relayModule {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            services.onepassword-connect-relay = {
              enable = true;
              interface = "podman0";
              address = "10.88.0.1";
              port = 18081;
              allowedSubnet = "10.88.0.0/16";
              target = "10.43.82.198:8000";
            };
          };
        in
        ''
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it fails an assertion when imps IPv6 mode moves imp-host off podman0";
      script =
        let
          system = buildModuleSystem relayModule {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            services.imp.ipv6.enable = true;
            services.onepassword-connect-relay = {
              enable = true;
              interface = "podman0";
              address = "10.88.0.1";
              port = 18081;
              allowedSubnet = "10.88.0.0/16";
              target = "10.43.82.198:8000";
            };
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "the Connect relay assumes imp-host on podman0; services.imp.ipv6.enable moves it to br-imphost"
              ]
            )
          } ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
  ];
in
pkgs.runCommand "onepassword-connect-relay-check"
  {
    nativeBuildInputs = [
      pkgs.diffutils
      pkgs.jq
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${testLib}/assert-files-equal.sh
    source ${pkgs.writeText "onepassword-connect-relay-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
