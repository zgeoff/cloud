# Evaluates services.atc-daemon apart from any host's config, with the pinned atc release, and
# checks the service, the config.json it links and the module's assertions. Each case evaluates
# its own config and runs on its own, in a fresh directory, under scripts/test-lib/run-cases.sh,
# which reports each case and fails the check when any case fails.
# Run: bun run test:nixos atc-daemon
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = ../../scripts/test-lib;
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  collectFailedAssertions = import ./test-utils/collect-failed-assertions.nix;

  # evaluates a minimal system with the module and one services.atc-daemon config
  buildDaemonSystem =
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

  cases = [
    {
      title = "it runs atc daemon on the listen address with both tokens as credentials, hardened, restarting when config.json changes";
      script =
        let
          atc = pkgs.callPackage ../packages/atc.nix { };
          service =
            (buildDaemonSystem {
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
            }).config.systemd.services.atc-daemon;
        in
        ''
          config=$(sed -n 's|^ln -sfn \(/nix/store/[a-z0-9]\{32\}-atc-daemon-config\.json\) .*$|\1|p' ${service.serviceConfig.ExecStartPre})
          # NixOS adds PATH to every service's environment; ExecStartPre is the link script, a
          # store path the module builds, whose content case "it links a config.json ..." checks
          jq -S . <<'EOF' | sed "s|$config|CONFIG|g" > actual
          ${builtins.toJSON {
            inherit (service)
              description
              wantedBy
              after
              wants
              restartTriggers
              ;
            environment = removeAttrs service.environment [ "PATH" ];
            serviceConfig = removeAttrs service.serviceConfig [ "ExecStartPre" ];
          }}
          EOF
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            description = "atc daemon";
            wantedBy = [ "multi-user.target" ];
            after = [
              "network-online.target"
              "tailscaled.service"
            ];
            wants = [ "network-online.target" ];
            # the config.json the link script links
            restartTriggers = [ "CONFIG" ];
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
      script =
        let
          system = buildDaemonSystem {
            enable = true;
            package = pkgs.callPackage ../packages/atc.nix { };
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
          script=${system.config.systemd.services.atc-daemon.serviceConfig.ExecStartPre}
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
      script =
        let
          system = buildDaemonSystem {
            enable = true;
            package = pkgs.callPackage ../packages/atc.nix { };
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
      script =
        let
          system = buildDaemonSystem {
            enable = true;
            package = pkgs.callPackage ../packages/atc.nix { };
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
          config=$(sed -n 's|^ln -sfn \(/nix/store/[a-z0-9]\{32\}-atc-daemon-config\.json\) .*$|\1|p' ${system.config.systemd.services.atc-daemon.serviceConfig.ExecStartPre})
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
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it fails no assertion for a valid config";
      script =
        let
          system = buildDaemonSystem {
            enable = true;
            package = pkgs.callPackage ../packages/atc.nix { };
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
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it rejects a principal granted a target that is not defined";
      script =
        let
          system = buildDaemonSystem {
            enable = true;
            package = pkgs.callPackage ../packages/atc.nix { };
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
          } ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it names every undefined grant of every principal in one message";
      script =
        let
          system = buildDaemonSystem {
            enable = true;
            package = pkgs.callPackage ../packages/atc.nix { };
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
          } ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it rejects a default target that is not defined";
      script =
        let
          system = buildDaemonSystem {
            enable = true;
            package = pkgs.callPackage ../packages/atc.nix { };
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
          } ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it adds no service, user or group, and fails no assertion, when it is off";
      script =
        let
          system = buildDaemonSystem { enable = false; };
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
                failedAssertions = collectFailedAssertions system;
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
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${testLib}/assert-files-equal.sh
    source ${pkgs.writeText "atc-daemon-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
