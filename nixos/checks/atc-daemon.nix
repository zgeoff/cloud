# Evaluates services.atc-daemon apart from any host's config, with a stand-in atc binary, and
# checks the service, the config.json it links and the module's assertions. Each case evaluates
# its own config, runs on its own and reports ok or not ok (case-helpers.sh); the check fails when
# any case fails. Run: nix build ./nixos#checks.x86_64-linux.atc-daemon
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs; };

  # evaluates a minimal system with the module and one services.atc-daemon config
  evalDaemon =
    daemon:
    lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ../modules/atc-daemon.nix
        {
          # a system needs these to evaluate; no case asserts on them
          system.stateVersion = "26.05";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          services.atc-daemon = daemon;
        }
      ];
    };

  # the messages of every assertion that fails, in the order the system lists them
  failedAssertions =
    system: map (a: a.message) (lib.filter (a: !a.assertion) system.config.assertions);

  # the service's own settings; NixOS adds PATH to every service's environment
  serviceOf =
    system:
    let
      service = system.config.systemd.services.atc-daemon;
    in
    {
      inherit (service) wantedBy after wants;
      environment = removeAttrs service.environment [ "PATH" ];
      # ExecStartPre is the link script, a store path the module builds; case
      # it-links-config-json checks what it runs
      serviceConfig = removeAttrs service.serviceConfig [ "ExecStartPre" ];
    };

  linkScriptOf = system: system.config.systemd.services.atc-daemon.serviceConfig.ExecStartPre;

  cases = [
    {
      title = "it runs atc daemon on the listen address with both tokens as credentials, hardened";
      dir = "service";
      script =
        let
          atc = pkgs.writeShellScriptBin "atc" "exec sleep infinity";
          system = evalDaemon {
            enable = true;
            package = atc;
            listen = "100.64.0.1:8415";
            tokenFile = "/run/fixture/gateway-token";
            impTokenFile = "/run/fixture/imp-token";
            targets.geoffcloud = {
              provider = "imp";
              url = "http://127.0.0.1:7070";
              tokenFile = "/run/credentials/atc-daemon.service/imp-token";
              impPrefix = "harness-";
            };
            defaultTarget = "geoffcloud";
            principals.fixture-client.targets = [ "geoffcloud" ];
          };
        in
        ''
          jq -S . > actual <<'EOF'
          ${builtins.toJSON (serviceOf system)}
          EOF
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            wantedBy = [ "multi-user.target" ];
            after = [
              "network-online.target"
              "tailscaled.service"
            ];
            wants = [ "network-online.target" ];
            environment = {
              HOME = "/var/lib/atc-daemon";
              XDG_RUNTIME_DIR = "/run/atc-daemon";
            };
            serviceConfig = {
              ExecStart = "${atc}/bin/atc daemon --listen 100.64.0.1:8415 --token-file %d/gateway-token";
              User = "atc";
              Group = "atc";
              StateDirectory = "atc-daemon";
              StateDirectoryMode = "0700";
              RuntimeDirectory = "atc-daemon";
              BindReadOnlyPaths = [ "${pkgs.glibc}/lib/ld-linux-x86-64.so.2:/lib64/ld-linux-x86-64.so.2" ];
              LoadCredential = [
                "gateway-token:/run/fixture/gateway-token"
                "imp-token:/run/fixture/imp-token"
              ];
              Restart = "on-failure";
              RestartSec = 5;
              NoNewPrivileges = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              PrivateDevices = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              RestrictSUIDSGID = true;
              LockPersonality = true;
              CapabilityBoundingSet = "";
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
              ];
            };
          }}
          EOF
          assert_files_equal expected actual
        '';
    }
    {
      title = "it links a config.json of the targets, principals and default target where atc reads it";
      dir = "link-config";
      script =
        let
          system = evalDaemon {
            enable = true;
            package = pkgs.writeShellScriptBin "atc" "exec sleep infinity";
            listen = "100.64.0.1:8415";
            tokenFile = "/run/fixture/gateway-token";
            impTokenFile = "/run/fixture/imp-token";
            targets.geoffcloud = {
              provider = "imp";
              url = "http://127.0.0.1:7070";
              tokenFile = "/run/credentials/atc-daemon.service/imp-token";
              impPrefix = "harness-";
            };
            defaultTarget = "geoffcloud";
            principals.fixture-client.targets = [ "geoffcloud" ];
          };
        in
        ''
          script=${linkScriptOf system}
          config=$(sed -n 's|^ln -sfn \(/nix/store/[a-z0-9]\{32\}-atc-daemon-config\.json\) /var/lib/atc-daemon/\.config/atc/config\.json$|\1|p' "$script")
          sed "s|$config|CONFIG|" "$script" > actual-script
          cat > expected-script <<'EOF'
          #!${pkgs.runtimeShell}
          set -eu
          mkdir -p /var/lib/atc-daemon/.config/atc
          ln -sfn CONFIG /var/lib/atc-daemon/.config/atc/config.json

          EOF
          assert_files_equal expected-script actual-script
          jq -S . "$config" > actual
          jq -S . > expected <<'EOF'
          {
            "defaultTarget": "geoffcloud",
            "principals": { "fixture-client": { "targets": ["geoffcloud"] } },
            "targets": {
              "geoffcloud": {
                "impPrefix": "harness-",
                "provider": "imp",
                "tokenFile": "/run/credentials/atc-daemon.service/imp-token",
                "url": "http://127.0.0.1:7070"
              }
            }
          }
          EOF
          assert_files_equal expected actual
        '';
    }
    {
      title = "it passes only the gateway token when impTokenFile is null";
      dir = "no-imp-token";
      script =
        let
          system = evalDaemon {
            enable = true;
            package = pkgs.writeShellScriptBin "atc" "exec sleep infinity";
            listen = "100.64.0.1:8415";
            tokenFile = "/run/fixture/gateway-token";
            impTokenFile = null;
            targets.geoffcloud = {
              provider = "imp";
              url = "http://127.0.0.1:7070";
              tokenFile = "/run/credentials/atc-daemon.service/imp-token";
              impPrefix = "harness-";
            };
            defaultTarget = "geoffcloud";
            principals.fixture-client.targets = [ "geoffcloud" ];
          };
        in
        ''
          assert_equals '["gateway-token:/run/fixture/gateway-token"]' \
            ${lib.escapeShellArg (builtins.toJSON system.config.systemd.services.atc-daemon.serviceConfig.LoadCredential)} \
            LoadCredential
        '';
    }
    {
      title = "it leaves defaultTarget out of config.json, and fails no assertion, when it is null";
      dir = "no-default-target";
      script =
        let
          system = evalDaemon {
            enable = true;
            package = pkgs.writeShellScriptBin "atc" "exec sleep infinity";
            listen = "100.64.0.1:8415";
            tokenFile = "/run/fixture/gateway-token";
            impTokenFile = "/run/fixture/imp-token";
            targets.geoffcloud = {
              provider = "imp";
              url = "http://127.0.0.1:7070";
              tokenFile = "/run/credentials/atc-daemon.service/imp-token";
              impPrefix = "harness-";
            };
            defaultTarget = null;
            principals.fixture-client.targets = [ "geoffcloud" ];
          };
        in
        ''
          config=$(sed -n 's|^ln -sfn \(/nix/store/[a-z0-9]\{32\}-atc-daemon-config\.json\) .*$|\1|p' ${linkScriptOf system})
          jq -S . "$config" > actual
          jq -S . > expected <<'EOF'
          {
            "principals": { "fixture-client": { "targets": ["geoffcloud"] } },
            "targets": {
              "geoffcloud": {
                "impPrefix": "harness-",
                "provider": "imp",
                "tokenFile": "/run/credentials/atc-daemon.service/imp-token",
                "url": "http://127.0.0.1:7070"
              }
            }
          }
          EOF
          assert_files_equal expected actual
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (failedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it fails no assertion for a valid config";
      dir = "valid";
      script =
        let
          system = evalDaemon {
            enable = true;
            package = pkgs.writeShellScriptBin "atc" "exec sleep infinity";
            listen = "100.64.0.1:8415";
            tokenFile = "/run/fixture/gateway-token";
            impTokenFile = "/run/fixture/imp-token";
            targets.geoffcloud = {
              provider = "imp";
              url = "http://127.0.0.1:7070";
              tokenFile = "/run/credentials/atc-daemon.service/imp-token";
              impPrefix = "harness-";
            };
            defaultTarget = "geoffcloud";
            principals.fixture-client.targets = [ "geoffcloud" ];
          };
        in
        ''
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (failedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it rejects a principal granted a target that is not defined";
      dir = "unknown-grant";
      script =
        let
          system = evalDaemon {
            enable = true;
            package = pkgs.writeShellScriptBin "atc" "exec sleep infinity";
            listen = "100.64.0.1:8415";
            tokenFile = "/run/fixture/gateway-token";
            impTokenFile = "/run/fixture/imp-token";
            targets.geoffcloud = {
              provider = "imp";
              url = "http://127.0.0.1:7070";
              tokenFile = "/run/credentials/atc-daemon.service/imp-token";
              impPrefix = "harness-";
            };
            defaultTarget = "geoffcloud";
            principals.fixture-client.targets = [
              "geoffcloud"
              "elsewhere"
            ];
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.atc-daemon.principals grants targets that services.atc-daemon.targets does not define: fixture-client -> elsewhere"
              ]
            )
          } ${lib.escapeShellArg (builtins.toJSON (failedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it names every undefined grant of every principal in one message";
      dir = "unknown-grants";
      script =
        let
          system = evalDaemon {
            enable = true;
            package = pkgs.writeShellScriptBin "atc" "exec sleep infinity";
            listen = "100.64.0.1:8415";
            tokenFile = "/run/fixture/gateway-token";
            impTokenFile = "/run/fixture/imp-token";
            targets.geoffcloud = {
              provider = "imp";
              url = "http://127.0.0.1:7070";
              tokenFile = "/run/credentials/atc-daemon.service/imp-token";
              impPrefix = "harness-";
            };
            defaultTarget = "geoffcloud";
            principals.alpha-client.targets = [ "nowhere" ];
            principals.beta-client.targets = [
              "geoffcloud"
              "elsewhere"
              "faraway"
            ];
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.atc-daemon.principals grants targets that services.atc-daemon.targets does not define: alpha-client -> nowhere, beta-client -> elsewhere, beta-client -> faraway"
              ]
            )
          } ${lib.escapeShellArg (builtins.toJSON (failedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it rejects a default target that is not defined";
      dir = "unknown-default-target";
      script =
        let
          system = evalDaemon {
            enable = true;
            package = pkgs.writeShellScriptBin "atc" "exec sleep infinity";
            listen = "100.64.0.1:8415";
            tokenFile = "/run/fixture/gateway-token";
            impTokenFile = "/run/fixture/imp-token";
            targets.geoffcloud = {
              provider = "imp";
              url = "http://127.0.0.1:7070";
              tokenFile = "/run/credentials/atc-daemon.service/imp-token";
              impPrefix = "harness-";
            };
            defaultTarget = "elsewhere";
            principals.fixture-client.targets = [ "geoffcloud" ];
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.atc-daemon.defaultTarget must name one of services.atc-daemon.targets"
              ]
            )
          } ${lib.escapeShellArg (builtins.toJSON (failedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it adds no service, user or group, and fails no assertion, when it is off";
      dir = "disabled";
      script =
        let
          system = evalDaemon { enable = false; };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON {
                service = false;
                user = false;
                group = false;
                failedAssertions = [ ];
              }
            )
          } ${
            lib.escapeShellArg (
              builtins.toJSON {
                service = system.config.systemd.services ? atc-daemon;
                user = system.config.users.users ? atc;
                group = system.config.users.groups ? atc;
                failedAssertions = failedAssertions system;
              }
            )
          } "what the module adds"
        '';
    }
  ];
in
pkgs.runCommand "atc-daemon-check"
  {
    nativeBuildInputs = [
      pkgs.diffutils
      pkgs.gnused
      pkgs.jq
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    source ${./case-helpers.sh}
    ${lib.concatMapStrings (c: ''
      case_${lib.replaceStrings [ "-" ] [ "_" ] c.dir}() {
      ${c.script}
      }
      run_case ${lib.escapeShellArg c.title} ${c.dir} case_${lib.replaceStrings [ "-" ] [ "_" ] c.dir}
    '') cases}
    require_cases_passed
    touch $out
  ''
