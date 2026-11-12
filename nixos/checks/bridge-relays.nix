# Evaluates services.bridge-relays apart from any host's config, beside imp's own module (the
# flake's pinned imp input), and checks the socket and the services each relay adds, the ports they
# admit in inet cloud_host and open on imp-host's bridge, and the assertion of each. Each case evaluates
# its own config through test-utils/build-module-system.nix and runs on its own, in a fresh
# directory, under test-support/shell/run-cases.sh, which reports each case and fails the check
# when any case fails.
# Run: bun run test:nixos bridge-relays
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
      ../modules/bridge-relays.nix
      imp.nixosModules.imp
    ];
  };

  relay = {
    interface = "podman0";
    address = "10.88.0.1";
    allowedSubnet = "10.88.0.0/16";
  };
  # the host's three relays, the Connect relay with the label and the values it had as the module's
  # only relay
  relays = {
    onepassword-connect-relay = relay // {
      label = "the Connect relay";
      port = 18081;
      target = "10.43.82.198:8000";
    };
    pepys-ingest-relay = relay // {
      port = 18082;
      target = "10.43.82.200:8080";
    };
    boxxy-worker-relay = relay // {
      port = 18083;
      target = "10.43.0.80:8091";
    };
  };

  cases = [
    {
      title = "it proxies the Connect relay socket on the relay address to the target, hardened, with the unit names and descriptions it had as the only relay, and restarts the socket and the proxy at a switch that moves the address";
      script =
        let
          system = buildModuleSystem relayModule {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            services.bridge-relays = relays;
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
      title = "it admits the podman0 subnet to each relay in the host table and opens each port on podman0";
      script =
        let
          system = buildModuleSystem relayModule {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            services.bridge-relays = relays;
          };
          admission = port: {
            inherit port;
            interface = "podman0";
            sourceCIDR = "10.88.0.0/16";
            destinationAddress = "10.88.0.1";
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                (admission 18083)
                (admission 18081)
                (admission 18082)
              ]
            )
          } ${lib.escapeShellArg (builtins.toJSON system.config.networking.cloudHost.admissions)} "the cloud_host admissions"
          assert_equals '[18081,18082,18083]' ${lib.escapeShellArg (builtins.toJSON system.config.networking.firewall.interfaces.podman0.allowedTCPPorts)} "the ports nixos-fw opens on podman0"
        '';
    }
    {
      title = "it gives the pepys ingest and boxxy worker relays units of their own, each dialing its Service";
      script =
        let
          system = buildModuleSystem relayModule {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            services.bridge-relays = relays;
          };
          units = system.config.systemd;
          proxy = "${units.package}/lib/systemd/systemd-socket-proxyd";
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            sockets = {
              pepys-ingest-relay = [ "10.88.0.1:18082" ];
              boxxy-worker-relay = [ "10.88.0.1:18083" ];
            };
            proxies = {
              pepys-ingest-relay = "${proxy} 10.43.82.200:8080";
              boxxy-worker-relay = "${proxy} 10.43.0.80:8091";
            };
            listens = {
              pepys-ingest-relay = {
                description = "the relay pepys-ingest-relay's socket on its listen address";
                after = [ "pepys-ingest-relay.socket" ];
              };
              boxxy-worker-relay = {
                description = "the relay boxxy-worker-relay's socket on its listen address";
                after = [ "boxxy-worker-relay.socket" ];
              };
            };
          }}
          EOF
          jq -S . > actual <<'EOF'
          ${builtins.toJSON {
            sockets = lib.genAttrs [ "pepys-ingest-relay" "boxxy-worker-relay" ] (
              name: units.sockets.${name}.listenStreams
            );
            proxies = lib.genAttrs [ "pepys-ingest-relay" "boxxy-worker-relay" ] (
              name: units.services.${name}.serviceConfig.ExecStart
            );
            listens = lib.genAttrs [ "pepys-ingest-relay" "boxxy-worker-relay" ] (name: {
              inherit (units.services."${name}-listen") description after;
            });
          }}
          EOF

          assert_files_equal expected actual
        '';
    }
    {
      title = "it admits nothing and opens no port when no relay is given, so no interface either";
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
            services.bridge-relays = relays;
          };
        in
        ''
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it fails an assertion for each relay when imps IPv6 mode moves imp-host off podman0";
      script =
        let
          system = buildModuleSystem relayModule {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            services.imp.ipv6.enable = true;
            services.bridge-relays = relays;
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "the relay boxxy-worker-relay assumes imp-host on podman0; services.imp.ipv6.enable moves it to br-imphost"
                "the Connect relay assumes imp-host on podman0; services.imp.ipv6.enable moves it to br-imphost"
                "the relay pepys-ingest-relay assumes imp-host on podman0; services.imp.ipv6.enable moves it to br-imphost"
              ]
            )
          } ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
  ];
in
pkgs.runCommand "bridge-relays-check"
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
    source ${pkgs.writeText "bridge-relays-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
