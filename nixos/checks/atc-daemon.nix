# Evaluates services.atc-daemon apart from any host's config, with the pinned atc release, and
# checks the service, the config.json it links and the module's assertions; one case reads the
# config.json that geoffcloud's own config links instead. Each other case evaluates its own config
# through test-utils/build-module-system.nix, most as buildDaemonSystem's valid config with the
# options the case sets. Each runs on its own, in a fresh directory, under
# test-support/shell/run-cases.sh, which reports each case and fails the check when any case fails.
# Run: bun run test:nixos atc-daemon
{
  nixpkgs,
  imp,
  geoffcloud,
}:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };
  collectFailedAssertions = import ./test-utils/collect-failed-assertions.nix;

  atc = pkgs.callPackage ../packages/atc.nix { };
  # the module's system for a valid services.atc-daemon: one target, granted to one principal and
  # named as the default; a case passes, as <options>, each option its scenario sets
  buildDaemonSystem =
    options:
    buildModuleSystem ../modules/atc-daemon.nix {
      services.atc-daemon = {
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
      }
      // options;
    };

  cases = [
    {
      title = "it runs atc daemon on the listen address with both tokens as credentials, hardened, restarting when config.json changes";
      script =
        let
          service = (buildDaemonSystem { }).config.systemd.services.atc-daemon;
        in
        ''
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

          assert_files_equal expected actual
        '';
    }
    {
      title = "it puts git on the service PATH, which atc runs to resolve the ref of a git workspace";
      script =
        let
          service = (buildDaemonSystem { }).config.systemd.services.atc-daemon;
        in
        ''
          actual=$(PATH='${service.environment.PATH}' git --version)

          assert_equals 'git version ${pkgs.git.version}' "$actual" "git on the service's PATH"
        '';
    }
    {
      title = "it links a config.json of the targets, principals, default target, agents and auth profiles where atc reads it";
      script =
        let
          system = buildDaemonSystem {
            authProfiles.github = {
              secret = "fixture-github";
              kind = "github";
            };
            agents = {
              claude.auth.profiles = [ "github" ];
              codex.args = [
                "--model"
                "gpt-5"
              ];
            };
          };
        in
        ''
          cat > expected-script <<'EOF'
          #!${pkgs.runtimeShell}
          set -eu
          mkdir -p /var/lib/atc-daemon/.config/atc
          ln -sfn CONFIG /var/lib/atc-daemon/.config/atc/config.json

          EOF
          jq -S . > expected <<'EOF'
          {
            "agents": {
              "claude": { "auth": { "profiles": ["github"] } },
              "codex": { "args": ["--model", "gpt-5"] }
            },
            "authProfiles": { "github": { "kind": "github", "secret": "fixture-github" } },
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

          script=${system.config.systemd.services.atc-daemon.serviceConfig.ExecStartPre}
          config=$(sed -n 's|^ln -sfn \(/nix/store/[a-z0-9]\{32\}-atc-daemon-config\.json\) /var/lib/atc-daemon/\.config/atc/config\.json$|\1|p' "$script")
          sed "s|$config|CONFIG|" "$script" > actual-script
          jq -S . "$config" > actual

          assert_files_equal expected-script actual-script
          assert_files_equal expected actual
        '';
    }
    {
      title = "it passes only the gateway token when impTokenFile is null";
      script =
        let
          system = buildDaemonSystem { impTokenFile = null; };
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            ExecStart = "${atc}/bin/atc daemon --listen 100.64.0.1:8415 --token-file %d/gateway-token";
            User = "atc";
            Group = "atc";
            StateDirectory = "atc-daemon";
            StateDirectoryMode = "0700";
            RuntimeDirectory = "atc-daemon";
            BindReadOnlyPaths = [ "${pkgs.glibc}/lib/ld-linux-x86-64.so.2:/lib64/ld-linux-x86-64.so.2" ];
            LoadCredential = [ "gateway-token:/run/fixture/gateway-token" ];
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
          }}
          EOF

          # ExecStartPre is the link script, whose content case "it links a config.json ..." checks
          jq -S . > actual <<'EOF'
          ${builtins.toJSON (
            removeAttrs system.config.systemd.services.atc-daemon.serviceConfig [ "ExecStartPre" ]
          )}
          EOF

          assert_files_equal expected actual
        '';
    }
    {
      title = "it leaves defaultTarget, agents and authProfiles out of config.json, and fails no assertion, when they are unset";
      script =
        let
          system = buildDaemonSystem { defaultTarget = null; };
        in
        ''
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

          config=$(sed -n 's|^ln -sfn \(/nix/store/[a-z0-9]\{32\}-atc-daemon-config\.json\) .*$|\1|p' ${system.config.systemd.services.atc-daemon.serviceConfig.ExecStartPre})
          jq -S . "$config" > actual

          assert_files_equal expected actual
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it fails no assertion for a valid config";
      script =
        let
          system = buildDaemonSystem { };
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
          system = buildDaemonSystem { defaultTarget = "elsewhere"; };
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
      title = "it names every auth profile an agent selects that is not defined";
      script =
        let
          system = buildDaemonSystem {
            authProfiles.github = {
              secret = "fixture-github";
              kind = "github";
            };
            agents = {
              claude.auth.profiles = [
                "github"
                "claude"
              ];
              codex.auth.profiles = [ "codex" ];
              grok = { };
            };
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.atc-daemon.agents select auth profiles that services.atc-daemon.authProfiles does not define: claude -> claude, codex -> codex"
              ]
            )
          } ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it names an MCP server whose auth profile is not defined, though the agent selects only defined ones";
      script =
        let
          system = buildDaemonSystem {
            authProfiles.github = {
              secret = "fixture-github";
              kind = "github";
            };
            agents.claude.auth = {
              profiles = [ "github" ];
              mcpServers.linear = {
                url = "https://mcp.linear.app/mcp";
                profile = "linear";
              };
            };
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.atc-daemon.agents select auth profiles that services.atc-daemon.authProfiles does not define: claude mcpServers.linear -> linear"
              ]
            )
          } ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it links geoffcloud a config.json whose target names the agent image and its atc, and whose claude signs in through the claude, github, linear and op-connect profiles of the broker";
      script = ''
        jq -S . > expected <<'EOF'
        {
          "agents": {
            "claude": {
              "auth": {
                "mcpServers": { "linear": { "profile": "linear", "url": "https://mcp.linear.app/mcp" } },
                "profiles": ["claude", "github", "linear", "op-connect"]
              }
            },
            "codex": {}
          },
          "authProfiles": {
            "claude": {
              "header": "authorization",
              "host": "api.anthropic.com",
              "scheme": "bearer",
              "secret": "claude-setup-token"
            },
            "github": { "kind": "github", "secret": "github-imp-agents" },
            "linear": {
              "header": "authorization",
              "host": "mcp.linear.app",
              "scheme": "bearer",
              "secret": "linear-imp-agents"
            },
            "op-connect": {
              "env": {
                "OP_CONNECT_HOST": "https://op-connect.imp.internal",
                "OP_CONNECT_TOKEN": "imp-broker-placeholder"
              },
              "header": "authorization",
              "host": "op-connect.imp.internal",
              "scheme": "bearer",
              "secret": "op-connect"
            }
          },
          "defaultTarget": "geoffcloud",
          "principals": {
            "0hpE6styFKfCcbWrvigzCp9HbZU5nVgY": { "targets": ["geoffcloud"] },
            "oZN3LOON2xgw3OKaULXs8wgRzGST6o5i": { "targets": ["geoffcloud"] }
          },
          "targets": {
            "geoffcloud": {
              "guestATC": "/usr/local/bin/atc",
              "image": "agent-ebd31ff",
              "impPrefix": "harness-",
              "provider": "imp",
              "tokenFile": "/run/credentials/atc-daemon.service/imp-token",
              "url": "http://127.0.0.1:7070"
            }
          }
        }
        EOF

        config=$(sed -n 's|^ln -sfn \(/nix/store/[a-z0-9]\{32\}-atc-daemon-config\.json\) .*$|\1|p' ${geoffcloud.config.systemd.services.atc-daemon.serviceConfig.ExecStartPre})
        jq -S . "$config" > actual

        assert_files_equal expected actual
      '';
    }
    {
      title = "it adds no service, user or group, and fails no assertion, when it is off";
      script =
        let
          system = buildModuleSystem ../modules/atc-daemon.nix {
            services.atc-daemon = {
              enable = false;
            };
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON {
                service = false;
                user = false;
                group = false;
              }
            )
          } ${
            lib.escapeShellArg (
              builtins.toJSON {
                service = system.config.systemd.services ? atc-daemon;
                user = system.config.users.users ? atc;
                group = system.config.users.groups ? atc;
              }
            )
          } "what the module adds"
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
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
