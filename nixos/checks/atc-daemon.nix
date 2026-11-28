# Evaluates services.atc-daemon apart from any host's config, with the pinned atc release, and
# checks the service, the config.json it links and the module's assertions; one case reads the
# config.json that geoffcloud's own config links instead. Each other case evaluates its own config
# through test-utils/build-module-system.nix, most as buildDaemonSystem's valid config with the
# options the case sets. Each runs on its own, in a fresh directory, as a bats test, which reports each case and fails the check when any case fails.
# No case starts atc, so a token file that atc refuses at start passes here: atc-daemon-vm starts
# the daemon as the host does.
# Run: bun run test:nixos atc-daemon
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
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };
  collectFailedAssertions = import ./test-utils/collect-failed-assertions.nix;

  atc = pkgs.callPackage ../packages/atc.nix { };
  # the first of a service's ExecStartPre: the script that links config.json
  linkScriptOf = service: builtins.head service.serviceConfig.ExecStartPre;
  # replaces the store paths of the link and staging scripts with LINK and STAGE
  maskScripts = "sed -E 's|/nix/store/[a-z0-9]{32}-atc-daemon-link-config|LINK|; s|/nix/store/[a-z0-9]{32}-atc-daemon-stage-gateway-token|STAGE|'";
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
      title = "it runs atc daemon on the listen address with both tokens as credentials and the gateway token staged in its runtime directory, hardened, restarting when config.json changes";
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
              ExecStartPre = [
                "LINK"
                "STAGE"
              ];
              ExecStart = "${atc}/bin/atc daemon --listen 100.64.0.1:8415 --token-file /run/atc-daemon/gateway-token";
              User = "atc";
              Group = "atc";
              StateDirectory = "atc-daemon";
              StateDirectoryMode = "0700";
              RuntimeDirectory = "atc-daemon";
              RuntimeDirectoryMode = "0700";
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

          config=$(sed -n 's|^ln -sfn \(/nix/store/[a-z0-9]\{32\}-atc-daemon-config\.json\) .*$|\1|p' ${linkScriptOf service})
          # NixOS adds PATH to every service's environment; ExecStartPre holds the link and staging
          # scripts, store paths the module builds: case "it links a config.json ..." checks the
          # first, and atc-daemon-vm runs the second
          jq -S . <<'EOF' | sed "s|$config|CONFIG|g" | ${maskScripts} > actual
          ${builtins.toJSON {
            inherit (service)
              description
              wantedBy
              after
              wants
              restartTriggers
              ;
            environment = removeAttrs service.environment [ "PATH" ];
            inherit (service) serviceConfig;
          }}
          EOF

          diff -u expected actual
        '';
    }
    {
      title = "it starts atc through a wrapper that reads each environment credential into its variable, and passes each file in as a credential";
      script =
        let
          service =
            (buildDaemonSystem {
              environmentCredentials.ATC_GIT_CLONE_TOKEN = "/run/fixture/git-clone-token";
            }).config.systemd.services.atc-daemon;
        in
        ''
          start='${service.serviceConfig.ExecStart}'
          wrapper=''${start%% *}
          rest=''${start#* }
          grep -q 'export ATC_GIT_CLONE_TOKEN=' "$wrapper"
          grep -q 'CREDENTIALS_DIRECTORY/env-ATC_GIT_CLONE_TOKEN' "$wrapper"
          assert_equal "$rest" '${atc}/bin/atc daemon --listen 100.64.0.1:8415 --token-file /run/atc-daemon/gateway-token'
          # credentials
          assert_equal ${lib.escapeShellArg (builtins.toJSON service.serviceConfig.LoadCredential)} ${
            lib.escapeShellArg (
              builtins.toJSON [
                "gateway-token:/run/fixture/gateway-token"
                "imp-token:/run/fixture/imp-token"
                "env-ATC_GIT_CLONE_TOKEN:/run/fixture/git-clone-token"
              ]
            )
          }
        '';
    }
    {
      title = "it exports an environment credential whose variable is named like a shell variable of its own";
      script =
        let
          service =
            (buildDaemonSystem {
              environmentCredentials.value = "/run/fixture/value-token";
            }).config.systemd.services.atc-daemon;
        in
        ''
          start='${service.serviceConfig.ExecStart}'
          wrapper=''${start%% *}
          dir=$(mktemp -d)
          printf 'fixture-value\n' > "$dir/env-value"
          actual=$(CREDENTIALS_DIRECTORY="$dir" "$wrapper" sh -c 'printf %s "''${value-absent}"')

          assert_equal "$actual" 'fixture-value'
        '';
    }
    {
      title = "it rejects an environment credential whose name is not a valid variable name";
      script =
        let
          system = buildDaemonSystem {
            environmentCredentials."BAD-NAME" = "/run/fixture/x";
          };
        in
        ''
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.atc-daemon.environmentCredentials names variables that are not valid environment variable names (^[A-Za-z_][A-Za-z0-9_]*$): BAD-NAME"
              ]
            )
          }
        '';
    }
    {
      title = "it rejects a clone credential that no environment credential sets";
      script =
        let
          system = buildDaemonSystem {
            workspaces.gitCredentials.FIXTURE_CLONE_TOKEN.hosts = [ "github.com" ];
          };
        in
        ''
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.atc-daemon.workspaces.gitCredentials lists variables that services.atc-daemon.environmentCredentials does not set: FIXTURE_CLONE_TOKEN"
              ]
            )
          }
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

          assert_equal "$actual" 'git version ${pkgs.git.version}'
        '';
    }
    {
      title = "it puts tar on the service PATH, which atc runs to upload a workspace it cloned with a credential";
      script =
        let
          service = (buildDaemonSystem { }).config.systemd.services.atc-daemon;
        in
        ''
          actual=$(PATH='${service.environment.PATH}' tar --version | head -n 1)

          assert_equal "$actual" 'tar (GNU tar) ${pkgs.gnutar.version}'
        '';
    }
    {
      title = "it links a config.json of the targets, principals, default target, agents, auth profiles and workspaces where atc reads it";
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
            environmentCredentials.FIXTURE_CLONE_TOKEN = "/run/fixture/clone-token";
            workspaces.gitCredentials.FIXTURE_CLONE_TOKEN.hosts = [ "github.com" ];
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
            },
            "workspaces": { "gitCredentials": { "FIXTURE_CLONE_TOKEN": { "hosts": ["github.com"] } } }
          }
          EOF

          script=${linkScriptOf system.config.systemd.services.atc-daemon}
          config=$(sed -n 's|^ln -sfn \(/nix/store/[a-z0-9]\{32\}-atc-daemon-config\.json\) /var/lib/atc-daemon/\.config/atc/config\.json$|\1|p' "$script")
          sed "s|$config|CONFIG|" "$script" > actual-script
          jq -S . "$config" > actual

          diff -u expected-script actual-script
          diff -u expected actual
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
            ExecStartPre = [
              "LINK"
              "STAGE"
            ];
            ExecStart = "${atc}/bin/atc daemon --listen 100.64.0.1:8415 --token-file /run/atc-daemon/gateway-token";
            User = "atc";
            Group = "atc";
            StateDirectory = "atc-daemon";
            StateDirectoryMode = "0700";
            RuntimeDirectory = "atc-daemon";
            RuntimeDirectoryMode = "0700";
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

          # ExecStartPre holds the link and staging scripts, which the first case's comment covers
          jq -S . <<'EOF' | ${maskScripts} > actual
          ${builtins.toJSON system.config.systemd.services.atc-daemon.serviceConfig}
          EOF

          diff -u expected actual
        '';
    }
    {
      title = "it leaves defaultTarget, agents, authProfiles and workspaces out of config.json, and fails no assertion, when they are unset";
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

          config=$(sed -n 's|^ln -sfn \(/nix/store/[a-z0-9]\{32\}-atc-daemon-config\.json\) .*$|\1|p' ${linkScriptOf system.config.systemd.services.atc-daemon})
          jq -S . "$config" > actual

          diff -u expected actual
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} '[]'
        '';
    }
    {
      title = "it fails no assertion for a valid config";
      script =
        let
          system = buildDaemonSystem { };
        in
        ''
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} '[]'
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
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.atc-daemon.principals grants targets that services.atc-daemon.targets does not define: fixture-client -> elsewhere"
              ]
            )
          }
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
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.atc-daemon.principals grants targets that services.atc-daemon.targets does not define: alpha-client -> nowhere, beta-client -> elsewhere, beta-client -> faraway"
              ]
            )
          }
        '';
    }
    {
      title = "it rejects a default target that is not defined";
      script =
        let
          system = buildDaemonSystem { defaultTarget = "elsewhere"; };
        in
        ''
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.atc-daemon.defaultTarget must name one of services.atc-daemon.targets"
              ]
            )
          }
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
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.atc-daemon.agents select auth profiles that services.atc-daemon.authProfiles does not define: claude -> claude, codex -> codex"
              ]
            )
          }
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
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.atc-daemon.agents select auth profiles that services.atc-daemon.authProfiles does not define: claude mcpServers.linear -> linear"
              ]
            )
          }
        '';
    }
    {
      title = "it links geoffcloud a config.json whose target names the agent image and its atc, boots each imp elastic at 1024 MiB up to 2048 MiB, and rebinds a session whose profiles changed, whose claude and boxxy sign in through the broker profiles, whose pepys-telemetry profile alone turns on telemetry and sets no variable, whose entries set no OpenTelemetry variable, whose boxxy loads the hook plug-in, the boxxy profile and the codex sign-in and commits as the owner, whose codex signs in through the ChatGPT subscription and selects the pepys-telemetry profile, whose claude, boxxy and boxxy-review turn the Artifact tool off in settings and env, whose boxxy-review loads the plug-in and takes the read-only clone token as its one GitHub profile, whose boxxy and nixie service clients may use the target, and which gets the verify upload address and the op:// reference of the upload token";
      script = ''
        jq -S . > expected <<'EOF'
        {
          "agents": {
            "boxxy": {
              "args": ["--plugin-dir", "/opt/boxxy/hook-plugin"],
              "auth": {
                "mcpServers": { "linear": { "profile": "linear", "url": "https://mcp.linear.app/mcp" } },
                "profiles": ["claude", "github", "linear", "op-connect", "pepys-telemetry", "boxxy", "codex"]
              },
              "env": {
                "CLAUDE_CODE_DISABLE_ARTIFACT": "1",
                "CLOUD_FILES_TOKEN_REF": "op://imp/files-upload-token/credential",
                "CLOUD_FILES_URL": "https://files.geoff.cloud/api/files",
                "GIT_AUTHOR_EMAIL": "3013783+zgeoff@users.noreply.github.com",
                "GIT_AUTHOR_NAME": "zgeoff",
                "GIT_COMMITTER_EMAIL": "3013783+zgeoff@users.noreply.github.com",
                "GIT_COMMITTER_NAME": "zgeoff"
              },
              "kind": "claude",
              "settings": { "enableArtifact": false, "permissions": { "deny": ["Artifact"] } }
            },
            "boxxy-review": {
              "args": ["--plugin-dir", "/opt/boxxy/hook-plugin"],
              "auth": { "profiles": ["claude", "github-review", "pepys-telemetry", "boxxy"] },
              "env": { "CLAUDE_CODE_DISABLE_ARTIFACT": "1" },
              "kind": "claude",
              "settings": { "enableArtifact": false, "permissions": { "deny": ["Artifact"] } }
            },
            "claude": {
              "auth": {
                "mcpServers": { "linear": { "profile": "linear", "url": "https://mcp.linear.app/mcp" } },
                "profiles": ["claude", "github", "linear", "op-connect", "pepys-telemetry"]
              },
              "env": {
                "CLAUDE_CODE_DISABLE_ARTIFACT": "1",
                "CLOUD_FILES_TOKEN_REF": "op://imp/files-upload-token/credential",
                "CLOUD_FILES_URL": "https://files.geoff.cloud/api/files"
              },
              "settings": { "enableArtifact": false, "permissions": { "deny": ["Artifact"] } }
            },
            "codex": { "auth": { "profiles": ["codex", "github", "pepys-telemetry"] } }
          },
          "authProfiles": {
            "boxxy": {
              "env": { "BOXXY_URL": "https://boxxy.imp.internal" },
              "header": "authorization",
              "host": "boxxy.imp.internal",
              "scheme": "bearer",
              "secret": "boxxy"
            },
            "claude": {
              "header": "authorization",
              "host": "api.anthropic.com",
              "scheme": "bearer",
              "secret": "claude-setup-token"
            },
            "codex": {
              "header": "authorization",
              "host": "chatgpt.com",
              "kind": "oauth",
              "scheme": "bearer",
              "secret": "codex-chatgpt"
            },
            "github": { "kind": "github", "secret": "github-imp-agents" },
            "github-review": { "kind": "github", "secret": "boxxy-github-token" },
            "linear": {
              "header": "authorization",
              "host": "mcp.linear.app",
              "scheme": "bearer",
              "secret": "linear-imp-agents"
            },
            "op-connect": {
              "env": {
                "OP_CONNECT_HOST": "https://op-connect.imp.internal",
                "OP_CONNECT_TOKEN": "broker-placeholder"
              },
              "header": "authorization",
              "host": "op-connect.imp.internal",
              "scheme": "bearer",
              "secret": "op-connect"
            },
            "pepys-telemetry": {
              "header": "authorization",
              "host": "pepys.imp.internal",
              "scheme": "bearer",
              "secret": "pepys-telemetry",
              "telemetry": { "logs": true }
            }
          },
          "defaultTarget": "geoffcloud",
          "principals": {
            "0hpE6styFKfCcbWrvigzCp9HbZU5nVgY": { "targets": ["geoffcloud"] },
            "service:boxxy": { "targets": ["geoffcloud"] },
            "service:nixie": { "targets": ["geoffcloud"] },
            "service:wringer-ro": { "targets": ["geoffcloud"] }
          },
          "targets": {
            "geoffcloud": {
              "guestATC": "/usr/local/bin/atc",
              "image": "agent",
              "impPrefix": "harness-",
              "maxMemoryMib": 2048,
              "memoryMib": 1024,
              "provider": "imp",
              "rebindChangedAuth": true,
              "tokenFile": "/run/credentials/atc-daemon.service/imp-token",
              "url": "http://127.0.0.1:7070"
            }
          },
          "workspaces": { "gitCredentials": { "ATC_GIT_CLONE_TOKEN": { "hosts": ["github.com"] } } }
        }
        EOF

        config=$(sed -n 's|^ln -sfn \(/nix/store/[a-z0-9]\{32\}-atc-daemon-config\.json\) .*$|\1|p' ${linkScriptOf geoffcloud.config.systemd.services.atc-daemon})
        jq -S . "$config" > actual

        diff -u expected actual
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
          # what the module adds
          assert_equal ${
            lib.escapeShellArg (
              builtins.toJSON {
                service = system.config.systemd.services ? atc-daemon;
                user = system.config.users.users ? atc;
                group = system.config.users.groups ? atc;
              }
            )
          } ${
            lib.escapeShellArg (
              builtins.toJSON {
                service = false;
                user = false;
                group = false;
              }
            )
          }
          # failed assertions
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} '[]'
        '';
    }
  ];
in
pkgs.runCommand "atc-daemon-check"
  {
    nativeBuildInputs = [
      (pkgs.bats.withLibraries (p: [
        p.bats-support
        p.bats-assert
      ]))
      pkgs.diffutils
      pkgs.gnused
      pkgs.jq
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    bats --timing --print-output-on-failure ${pkgs.writeText "atc-daemon.bats" (renderCases cases)}
    touch $out
  ''
