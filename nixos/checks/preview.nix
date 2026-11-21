# Evaluates services.preview apart from any host's config and checks the units it defines, runs
# the preview-image unit's script against a stand-in podman that answers for impd
# (test-utils/build-stub-imp-host-podman.nix) and a stand-in sleep (test-utils/build-stub-sleep.nix),
# and builds the package to check that it carries the service's modules and none of its tests,
# and that its typed impd client loads from the dependencies it carries.
# Each case runs on its own, in a fresh directory, as a bats test.
# Run: bun run test:nixos preview
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };
  collectFailedAssertions = import ./test-utils/collect-failed-assertions.nix;
  package = pkgs.callPackage ../packages/preview.nix { };
  stubImpHostPodman = import ./test-utils/build-stub-imp-host-podman.nix { inherit pkgs; };
  stubSleep = import ./test-utils/build-stub-sleep.nix { inherit pkgs; };
  buildStorePathGaps = import ./test-utils/build-store-path-gaps.nix { inherit pkgs; };
  # the spendCap cases only read the proxy's path, so the binary never runs
  stubCountingProxy = pkgs.writeShellScriptBin "counting-proxy" "exit 1";

  # the service's settings with impImage and impRegistryImage as given, for the preview-image cases
  buildImageSystem =
    imageSettings:
    buildModuleSystem ../modules/preview.nix {
      services.preview = {
        enable = true;
        inherit package;
        linkListen = "100.64.0.1:8417";
        webhookListen = "100.64.0.1:8418";
        baseURL = "http://cloudhost:8417";
        repos = [ "acme/greenhouse" ];
        impdURL = "http://127.0.0.1:7070";
        impDomain = "imps.example.org";
        webhookSecretFile = "/run/fixture/webhook-secret";
        githubAppClientIDFile = "/run/fixture/github-app-client-id";
        githubAppKeyFile = "/run/fixture/github-app-key";
        impTokenFile = "/run/fixture/imp-token";
      }
      // imageSettings;
    };
  imagePackage =
    (buildImageSystem {
      impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
    }).config.services.preview.imageScript;
  imageScript = lib.getExe imagePackage;

  cases = [
    {
      title = "it runs the service with its settings in the environment and its secrets as credentials, hardened, once the secrets exist";
      script =
        let
          system = buildModuleSystem ../modules/preview.nix {
            services.preview = {
              enable = true;
              inherit package;
              linkListen = "100.64.0.1:8417";
              webhookListen = "100.64.0.1:8418";
              baseURL = "http://cloudhost:8417";
              repos = [
                "acme/greenhouse"
                "nursery/*"
              ];
              impdURL = "http://127.0.0.1:7070";
              impDomain = "imps.example.org";
              impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
              impGitHubSecret = "gh";
              impModelSecret = "preview-model";
              webhookSecretFile = "/run/fixture/webhook-secret";
              githubAppClientIDFile = "/run/fixture/github-app-client-id";
              githubAppKeyFile = "/run/fixture/github-app-key";
              impTokenFile = "/run/fixture/imp-token";
            };
          };
          service = system.config.systemd.services.preview;
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            description = "preview service";
            wantedBy = [ "multi-user.target" ];
            after = [
              "network-online.target"
              "tailscaled.service"
              "preview-image.service"
            ];
            wants = [
              "network-online.target"
              "preview-image.service"
            ];
            unitConfig.ConditionPathExists = [
              "/run/fixture/webhook-secret"
              "/run/fixture/github-app-client-id"
              "/run/fixture/github-app-key"
              "/run/fixture/imp-token"
            ];
            environment = {
              PREVIEW_LINK_LISTEN = "100.64.0.1:8417";
              PREVIEW_WEBHOOK_LISTEN = "100.64.0.1:8418";
              PREVIEW_BASE_URL = "http://cloudhost:8417";
              PREVIEW_REPOS = "acme/greenhouse,nursery/*";
              PREVIEW_SLOTS = "1";
              PREVIEW_IDLE_MINUTES = "30";
              PREVIEW_IMPD_URL = "http://127.0.0.1:7070";
              PREVIEW_IMP_DOMAIN = "imps.example.org";
              PREVIEW_IMP_IMAGE = "pv-base";
              PREVIEW_IMP_MEMORY_MIB = "1024";
              PREVIEW_IMP_MAX_MEMORY_MIB = "2048";
              PREVIEW_IMP_GITHUB_SECRET = "gh";
              PREVIEW_IMP_MODEL_SECRET = "preview-model";
              PREVIEW_DATABASE = "/var/lib/preview/previews.sqlite";
              HOME = "/var/lib/preview";
              BUN_RUNTIME_TRANSPILER_CACHE_PATH = "0";
            };
            serviceConfig = {
              ExecStart = "${package}/bin/preview-service";
              DynamicUser = true;
              StateDirectory = "preview";
              StateDirectoryMode = "0700";
              LoadCredential = [
                "webhook-secret:/run/fixture/webhook-secret"
                "github-app-client-id:/run/fixture/github-app-client-id"
                "github-app-key:/run/fixture/github-app-key"
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

          # NixOS adds PATH to every service's environment
          jq -S . > actual <<'EOF'
          ${builtins.toJSON {
            inherit (service)
              description
              wantedBy
              after
              wants
              serviceConfig
              ;
            unitConfig = { inherit (service.unitConfig) ConditionPathExists; };
            environment = removeAttrs service.environment [ "PATH" ];
          }}
          EOF

          diff -u expected actual
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} '[]'
        '';
    }
    {
      title = "it leaves the GitHub and model grants out when impGitHubSecret and impModelSecret are null";
      script =
        let
          system = buildModuleSystem ../modules/preview.nix {
            services.preview = {
              enable = true;
              inherit package;
              linkListen = "100.64.0.1:8417";
              webhookListen = "100.64.0.1:8418";
              baseURL = "http://cloudhost:8417";
              repos = [ "acme/greenhouse" ];
              impdURL = "http://127.0.0.1:7070";
              impDomain = "imps.example.org";
              impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
              webhookSecretFile = "/run/fixture/webhook-secret";
              githubAppClientIDFile = "/run/fixture/github-app-client-id";
              githubAppKeyFile = "/run/fixture/github-app-key";
              impTokenFile = "/run/fixture/imp-token";
            };
          };
        in
        ''
          # the grant's variable is set
          assert_equal ${
            lib.boolToString (system.config.systemd.services.preview.environment ? PREVIEW_IMP_GITHUB_SECRET)
          } false
          # the model grant's variable is set
          assert_equal ${
            lib.boolToString (system.config.systemd.services.preview.environment ? PREVIEW_IMP_MODEL_SECRET)
          } false
        '';
    }
    {
      title = "it sets the repositories, model secret, time limit and idle time of the contract run once contractRepos lists a repository";
      script =
        let
          system = buildModuleSystem ../modules/preview.nix {
            services.preview = {
              enable = true;
              inherit package;
              linkListen = "100.64.0.1:8417";
              webhookListen = "100.64.0.1:8418";
              baseURL = "http://cloudhost:8417";
              repos = [ "acme/greenhouse" ];
              impdURL = "http://127.0.0.1:7070";
              impDomain = "imps.example.org";
              impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
              contractRepos = [
                "acme/greenhouse"
                "nursery/*"
              ];
              contractModelSecret = "preview-model";
              contractTimeoutMinutes = 15;
              contractIdleMinutes = 7;
              webhookSecretFile = "/run/fixture/webhook-secret";
              githubAppClientIDFile = "/run/fixture/github-app-client-id";
              githubAppKeyFile = "/run/fixture/github-app-key";
              impTokenFile = "/run/fixture/imp-token";
            };
          };
          environment = system.config.systemd.services.preview.environment;
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            PREVIEW_CONTRACT_REPOS = "acme/greenhouse,nursery/*";
            PREVIEW_CONTRACT_MODEL_SECRET = "preview-model";
            PREVIEW_CONTRACT_TIMEOUT_MINUTES = "15";
            PREVIEW_CONTRACT_IDLE_MINUTES = "7";
          }}
          EOF

          jq -S . > actual <<'EOF'
          ${builtins.toJSON {
            inherit (environment)
              PREVIEW_CONTRACT_REPOS
              PREVIEW_CONTRACT_MODEL_SECRET
              PREVIEW_CONTRACT_TIMEOUT_MINUTES
              PREVIEW_CONTRACT_IDLE_MINUTES
              ;
          }}
          EOF

          diff -u expected actual
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} '[]'
        '';
    }
    {
      title = "it leaves the settings of the contract run out when contractRepos is empty";
      script =
        let
          system = buildModuleSystem ../modules/preview.nix {
            services.preview = {
              enable = true;
              inherit package;
              linkListen = "100.64.0.1:8417";
              webhookListen = "100.64.0.1:8418";
              baseURL = "http://cloudhost:8417";
              repos = [ "acme/greenhouse" ];
              impdURL = "http://127.0.0.1:7070";
              impDomain = "imps.example.org";
              impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
              contractModelSecret = "preview-model";
              webhookSecretFile = "/run/fixture/webhook-secret";
              githubAppClientIDFile = "/run/fixture/github-app-client-id";
              githubAppKeyFile = "/run/fixture/github-app-key";
              impTokenFile = "/run/fixture/imp-token";
            };
          };
          names = builtins.attrNames system.config.systemd.services.preview.environment;
        in
        ''
          assert_equal ${lib.escapeShellArg (builtins.toJSON (builtins.filter (lib.hasPrefix "PREVIEW_CONTRACT_") names))} '[]'
        '';
    }
    {
      title = "it refuses contractRepos without contractModelSecret";
      script =
        let
          system = buildModuleSystem ../modules/preview.nix {
            services.preview = {
              enable = true;
              inherit package;
              linkListen = "100.64.0.1:8417";
              webhookListen = "100.64.0.1:8418";
              baseURL = "http://cloudhost:8417";
              repos = [ "acme/greenhouse" ];
              impdURL = "http://127.0.0.1:7070";
              impDomain = "imps.example.org";
              impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
              contractRepos = [ "acme/greenhouse" ];
              webhookSecretFile = "/run/fixture/webhook-secret";
              githubAppClientIDFile = "/run/fixture/github-app-client-id";
              githubAppKeyFile = "/run/fixture/github-app-key";
              impTokenFile = "/run/fixture/imp-token";
            };
          };
        in
        ''
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.preview.contractModelSecret must name the model secret when contractRepos lists a repository."
              ]
            )
          }
        '';
    }
    {
      title = "it sets the counting proxy settings and admits the podman0 subnet to the model route listener once spendCap is on";
      script =
        let
          system = buildModuleSystem ../modules/preview.nix {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            services.preview = {
              enable = true;
              inherit package;
              linkListen = "100.64.0.1:8417";
              webhookListen = "100.64.0.1:8418";
              baseURL = "http://cloudhost:8417";
              repos = [ "acme/greenhouse" ];
              impdURL = "http://127.0.0.1:7070";
              impDomain = "imps.example.org";
              impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
              impModelSecret = "preview-model-counted";
              spendCap = {
                enable = true;
                package = stubCountingProxy;
                interface = "podman0";
                address = "10.88.0.1";
                port = 18082;
                allowedSubnet = "10.88.0.0/16";
                model = "claude-test-model";
                prices = {
                  input = 1;
                  cache_write = 1.25;
                  cache_write_1h = 2;
                  cached_input = 0.1;
                  output = 5;
                };
                limitDollars = 3;
              };
              webhookSecretFile = "/run/fixture/webhook-secret";
              githubAppClientIDFile = "/run/fixture/github-app-client-id";
              githubAppKeyFile = "/run/fixture/github-app-key";
              impTokenFile = "/run/fixture/imp-token";
            };
          };
          environment = system.config.systemd.services.preview.environment;
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            PREVIEW_SPEND_LISTEN = "10.88.0.1:18082";
            PREVIEW_SPEND_PROXY = "${stubCountingProxy}/bin/counting-proxy";
            PREVIEW_SPEND_DIRECTORY = "/var/lib/preview/spend";
            PREVIEW_SPEND_UPSTREAM = "https://api.anthropic.com";
            PREVIEW_SPEND_MODEL = "claude-test-model";
            PREVIEW_SPEND_PRICES = builtins.toJSON {
              input = 1;
              cache_write = 1.25;
              cache_write_1h = 2;
              cached_input = 0.1;
              output = 5;
            };
            PREVIEW_SPEND_LIMIT_DOLLARS = "3";
          }}
          EOF

          jq -S . > actual <<'EOF'
          ${builtins.toJSON (lib.filterAttrs (name: _: lib.hasPrefix "PREVIEW_SPEND_" name) environment)}
          EOF

          diff -u expected actual
          # the cloud_host admissions
          assert_equal ${lib.escapeShellArg (builtins.toJSON system.config.networking.cloudHost.admissions)} ${
            lib.escapeShellArg (
              builtins.toJSON [
                {
                  port = 18082;
                  interface = "podman0";
                  sourceCIDR = "10.88.0.0/16";
                  destinationAddress = "10.88.0.1";
                }
              ]
            )
          }
          # the ports nixos-fw opens on podman0
          assert_equal ${lib.escapeShellArg (builtins.toJSON system.config.networking.firewall.interfaces.podman0.allowedTCPPorts)} '[18082]'
          # failed assertions
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} '[]'
        '';
    }
    {
      title = "it hands the service the long-prompt prices once spendCap names them";
      script =
        let
          system = buildModuleSystem ../modules/preview.nix {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            services.preview = {
              enable = true;
              inherit package;
              linkListen = "100.64.0.1:8417";
              webhookListen = "100.64.0.1:8418";
              baseURL = "http://cloudhost:8417";
              repos = [ "acme/greenhouse" ];
              impdURL = "http://127.0.0.1:7070";
              impDomain = "imps.example.org";
              impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
              impModelSecret = "preview-model-counted";
              spendCap = {
                enable = true;
                package = stubCountingProxy;
                interface = "podman0";
                address = "10.88.0.1";
                port = 18082;
                allowedSubnet = "10.88.0.0/16";
                model = "claude-test-model";
                prices = {
                  input = 1;
                  cache_write = 1.25;
                  cache_write_1h = 2;
                  cached_input = 0.1;
                  output = 5;
                  long_prompt = {
                    over_tokens = 200000;
                    input = 2;
                    cache_write = 2.5;
                    cache_write_1h = 4;
                    cached_input = 0.2;
                    output = 7.5;
                  };
                };
              };
              webhookSecretFile = "/run/fixture/webhook-secret";
              githubAppClientIDFile = "/run/fixture/github-app-client-id";
              githubAppKeyFile = "/run/fixture/github-app-key";
              impTokenFile = "/run/fixture/imp-token";
            };
          };
        in
        ''
          jq -S . > expected <<'EOF'
          {
            "input": 1,
            "cache_write": 1.25,
            "cache_write_1h": 2,
            "cached_input": 0.1,
            "output": 5,
            "long_prompt": {
              "over_tokens": 200000,
              "input": 2,
              "cache_write": 2.5,
              "cache_write_1h": 4,
              "cached_input": 0.2,
              "output": 7.5
            }
          }
          EOF

          jq -S . > actual <<'EOF'
          ${system.config.systemd.services.preview.environment.PREVIEW_SPEND_PRICES}
          EOF

          diff -u expected actual
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} '[]'
        '';
    }
    {
      title = "it leaves the counting proxy settings, the admission and the open port out when spendCap is off";
      script =
        let
          system = buildModuleSystem ../modules/preview.nix {
            services.preview = {
              enable = true;
              inherit package;
              linkListen = "100.64.0.1:8417";
              webhookListen = "100.64.0.1:8418";
              baseURL = "http://cloudhost:8417";
              repos = [ "acme/greenhouse" ];
              impdURL = "http://127.0.0.1:7070";
              impDomain = "imps.example.org";
              impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
              impModelSecret = "preview-model";
              webhookSecretFile = "/run/fixture/webhook-secret";
              githubAppClientIDFile = "/run/fixture/github-app-client-id";
              githubAppKeyFile = "/run/fixture/github-app-key";
              impTokenFile = "/run/fixture/imp-token";
            };
          };
          names = builtins.attrNames system.config.systemd.services.preview.environment;
        in
        ''
          # the counting proxy's variables
          assert_equal ${lib.escapeShellArg (builtins.toJSON (builtins.filter (lib.hasPrefix "PREVIEW_SPEND_") names))} '[]'
          # the cloud_host admissions
          assert_equal ${lib.escapeShellArg (builtins.toJSON system.config.networking.cloudHost.admissions)} '[]'
          # the interfaces nixos-fw opens ports on
          assert_equal ${lib.escapeShellArg (builtins.toJSON system.config.networking.firewall.interfaces)} '{}'
        '';
    }
    {
      title = "it refuses spendCap without impModelSecret";
      script =
        let
          system = buildModuleSystem ../modules/preview.nix {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            services.preview = {
              enable = true;
              inherit package;
              linkListen = "100.64.0.1:8417";
              webhookListen = "100.64.0.1:8418";
              baseURL = "http://cloudhost:8417";
              repos = [ "acme/greenhouse" ];
              impdURL = "http://127.0.0.1:7070";
              impDomain = "imps.example.org";
              impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
              spendCap = {
                enable = true;
                package = stubCountingProxy;
                interface = "podman0";
                address = "10.88.0.1";
                port = 18082;
                allowedSubnet = "10.88.0.0/16";
                model = "claude-test-model";
                prices = {
                  input = 1;
                  cache_write = 1.25;
                  cache_write_1h = 2;
                  cached_input = 0.1;
                  output = 5;
                };
              };
              webhookSecretFile = "/run/fixture/webhook-secret";
              githubAppClientIDFile = "/run/fixture/github-app-client-id";
              githubAppKeyFile = "/run/fixture/github-app-key";
              impTokenFile = "/run/fixture/imp-token";
            };
          };
        in
        ''
          assert_equal ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.preview.spendCap needs impModelSecret, whose upstream reaches the model route listener."
              ]
            )
          }
        '';
    }
    {
      title = "it adds the pinned image to impd once imp-host runs, at each switch that changes the pin and each imp-host restart, before the service starts, and starts again after a failed start";
      script =
        let
          system = buildImageSystem {
            impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
          };
          service = system.config.systemd.services.preview-image;
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            description = "the preview imps' image in impd";
            wantedBy = [
              "multi-user.target"
              "imp-host.service"
            ];
            after = [ "imp-host.service" ];
            requires = [ "imp-host.service" ];
            restartIfChanged = true;
            startLimitIntervalSec = 3600;
            startLimitBurst = 10;
            environment = {
              PREVIEW_IMAGE_NAME = "pv-base";
              PREVIEW_IMAGE_REF = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
            };
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              Restart = "on-failure";
              RestartSec = 10;
              ExecStart = imageScript;
              TimeoutStartSec = "30min";
              NoNewPrivileges = true;
              PrivateTmp = true;
            };
          }}
          EOF

          # NixOS adds PATH to every service's environment
          jq -S . > actual <<'EOF'
          ${builtins.toJSON {
            inherit (service)
              description
              wantedBy
              after
              requires
              restartIfChanged
              startLimitIntervalSec
              startLimitBurst
              serviceConfig
              ;
            environment = removeAttrs service.environment [ "PATH" ];
          }}
          EOF

          diff -u expected actual
        '';
    }
    {
      title = "it boots each preview from the image name that the preview-image unit adds";
      script =
        let
          environments = lib.mapAttrs (_: service: service.environment) {
            inherit
              ((buildImageSystem {
                impImage = "pv-sandbox";
                impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
              }).config.systemd.services
              )
              preview
              preview-image
              ;
          };
        in
        ''
          # the name the unit adds
          assert_equal ${lib.escapeShellArg environments.preview-image.PREVIEW_IMAGE_NAME} pv-sandbox
          # the name the service boots
          assert_equal ${lib.escapeShellArg environments.preview.PREVIEW_IMP_IMAGE} pv-sandbox
        '';
    }
    {
      title = "it refuses an image reference that no digest pins";
      script = ''
        assert_equal ${
          lib.boolToString
            (builtins.tryEval
              (buildImageSystem { impRegistryImage = "ghcr.io/example/imp-base:1.2.3"; })
              .config.systemd.services.preview-image.environment.PREVIEW_IMAGE_REF
            ).success
        } false
      '';
    }
    {
      title = "it carries in the preview-image script closure every store path the script names";
      script = ''
        diff -u /dev/null ${buildStorePathGaps imagePackage}
      '';
    }
    {
      title = "it adds the digest-pinned image under the preview image name and pins the name when impd holds no image of that name, and leaves the other impd images alone, even when its mounts predate the imp-host container";
      script = ''
        mkdir home tmp impd
        echo '[{"id":"img-1","name":"base","ref":"ghcr.io/example/imp-base:1.0.0","digest":"imp-build-aa","source":"oci","createdAt":"2026-02-03T04:05:06.000Z","sizeBytes":12}]' > impd/images.json
        touch impd/stale-view

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u - out <<'EOF'
        preview-image: adding ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} to impd as pv-base
        preview-image: pinning pv-base
        preview-image: impd holds pv-base at ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}, pinned
        EOF
        diff -u /dev/null err
        diff -u - impd/calls <<'EOF'
        ["exec","imp-host","curl","-sS","--max-time","5","http://127.0.0.1:7070/health"]
        ["exec","-e","HOME=/root","imp-host","impz","image","ls","--json"]
        ["exec","-e","HOME=/root","imp-host","impz","image","add","ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}","--name","pv-base","--json"]
        ["exec","-e","HOME=/root","imp-host","impz","image","pin","pv-base"]
        EOF
        # impd's images
        assert_equal "$(jq -c 'map([.name, .ref, .pinned == true])' impd/images.json)" '[["base","ghcr.io/example/imp-base:1.0.0",false],["pv-base","ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}",true]]'
        # the pauses
        assert [ ! -e sleep.log ]
        assert [ ! -L sleep.log ]
      '';
    }
    {
      title = "it points the pinned name at the new reference in place of an older one, and pins nothing again";
      script = ''
        mkdir home tmp impd
        echo '[{"id":"img-2","name":"pv-base","ref":"ghcr.io/example/imp-base:1.2.2@sha256:${lib.strings.replicate 64 "b"}","digest":"imp-build-bb","source":"oci","createdAt":"2026-02-03T04:05:06.000Z","sizeBytes":12,"pinned":true}]' > impd/images.json

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u - out <<'EOF'
        preview-image: adding ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} to impd as pv-base, in place of ghcr.io/example/imp-base:1.2.2@sha256:${lib.strings.replicate 64 "b"}
        preview-image: impd holds pv-base at ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}, pinned
        EOF
        diff -u /dev/null err
        diff -u - impd/calls <<'EOF'
        ["exec","imp-host","curl","-sS","--max-time","5","http://127.0.0.1:7070/health"]
        ["exec","-e","HOME=/root","imp-host","impz","image","ls","--json"]
        ["exec","-e","HOME=/root","imp-host","impz","image","add","ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}","--name","pv-base","--json"]
        EOF
        # impd's images
        assert_equal "$(jq -c 'map([.name, .ref, .pinned])' impd/images.json)" '[["pv-base","ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}",true]]'
      '';
    }
    {
      title = "it adds and pins nothing when the name already holds the reference and a pin";
      script = ''
        mkdir home tmp impd
        echo '[{"id":"img-3","name":"pv-base","ref":"ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}","digest":"imp-build-cc","source":"oci","createdAt":"2026-02-03T04:05:06.000Z","sizeBytes":12,"pinned":true}]' > impd/images.json
        cp impd/images.json before.json

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equal "$status" 0
        # the output
        assert_equal "$(cat out)" "preview-image: impd holds pv-base at ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}, pinned"
        diff -u /dev/null err
        diff -u - impd/calls <<'EOF'
        ["exec","imp-host","curl","-sS","--max-time","5","http://127.0.0.1:7070/health"]
        ["exec","-e","HOME=/root","imp-host","impz","image","ls","--json"]
        EOF
        diff -u before.json impd/images.json
      '';
    }
    {
      title = "it pins the name, with no add, when the name holds the reference without a pin";
      script = ''
        mkdir home tmp impd
        echo '[{"id":"img-3","name":"pv-base","ref":"ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}","digest":"imp-build-cc","source":"oci","createdAt":"2026-02-03T04:05:06.000Z","sizeBytes":12,"pinned":false}]' > impd/images.json

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u - out <<'EOF'
        preview-image: pinning pv-base
        preview-image: impd holds pv-base at ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}, pinned
        EOF
        diff -u /dev/null err
        diff -u - impd/calls <<'EOF'
        ["exec","imp-host","curl","-sS","--max-time","5","http://127.0.0.1:7070/health"]
        ["exec","-e","HOME=/root","imp-host","impz","image","ls","--json"]
        ["exec","-e","HOME=/root","imp-host","impz","image","pin","pv-base"]
        EOF
        # impd's images
        assert_equal "$(jq -c 'map([.name, .ref, .pinned])' impd/images.json)" '[["pv-base","ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}",true]]'
      '';
    }
    {
      title = "it waits for impd to answer, pausing between tries, before it adds and pins the image";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 2 > impd/unreachable

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equal "$status" 0
        # the error
        assert_equal "$(cat err)" 'preview-image: try 1: Error: no container with name or ID "imp-host" found: no such container'
        diff -u - sleep.log <<'EOF'
        ["2"]
        ["2"]
        EOF
        diff -u - impd/calls <<'EOF'
        ["exec","imp-host","curl","-sS","--max-time","5","http://127.0.0.1:7070/health"]
        ["exec","imp-host","curl","-sS","--max-time","5","http://127.0.0.1:7070/health"]
        ["exec","imp-host","curl","-sS","--max-time","5","http://127.0.0.1:7070/health"]
        ["exec","-e","HOME=/root","imp-host","impz","image","ls","--json"]
        ["exec","-e","HOME=/root","imp-host","impz","image","add","ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}","--name","pv-base","--json"]
        ["exec","-e","HOME=/root","imp-host","impz","image","pin","pv-base"]
        EOF
      '';
    }
    {
      title = "it prints each failed try whose error differs from the one before, while impd starts and then refuses the call, with what the exec sees of the impd token file and the impd start";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 2 > impd/unreachable
        echo 2 > impd/unauthorized
        mkdir -p impd/container/var/lib/imp impd/container/root/.config/impz impd/container/proc/4242
        printf 'imp_fixture_root\n' > impd/container/var/lib/imp/token
        touch -d @1793300070 impd/container/var/lib/imp/token
        ln -s ../../../var/lib/imp/token impd/container/root/.config/impz/token
        printf 'cpu  10 0 10 1000 0 0 0 0 0 0\nbtime 1793300000\n' > impd/container/proc/stat
        echo impd > impd/container/proc/4242/comm
        echo '4242 (impd) S 1 4242 4242 0 -1 4194560 100 0 0 0 5 3 0 0 20 0 9 0 6000 512000 300' > impd/container/proc/4242/stat
        inode=$(stat -c %i impd/container/var/lib/imp/token)

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u - err <<EOF
        preview-image: try 1: Error: no container with name or ID "imp-host" found: no such container
        preview-image: try 3: impz: unauthorized: set IMP_TOKEN to the token from <IMP_DATA_DIR>/token, or run impz login <url>; impz's token file: inode $inode, modified 2026-10-29T18:54:30Z; impd 4242 started 2026-10-29T18:54:20Z
        EOF
        # the pauses
        assert_equal "$(wc -l < sleep.log)" 4
        # the token's appearances in the log
        assert_equal "$(grep -c imp_fixture_root err)" 0
      '';
    }
    {
      title = "it says the exec sees no token file when impd refuses the call and the impz token file is missing";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 1 > impd/unauthorized
        mkdir -p impd/container/root/.config/impz impd/container/proc
        ln -s ../../../var/lib/imp/token impd/container/root/.config/impz/token
        printf 'btime 1793300000\n' > impd/container/proc/stat

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equal "$status" 0
        # the error
        assert_equal "$(cat err)" "preview-image: try 1: impz: unauthorized: set IMP_TOKEN to the token from <IMP_DATA_DIR>/token, or run impz login <url>; impz's token file: missing"
        diff -u - impd/calls <<'EOF'
        ["exec","imp-host","curl","-sS","--max-time","5","http://127.0.0.1:7070/health"]
        ["exec","-e","HOME=/root","imp-host","impz","image","ls","--json"]
        ["exec","-i","imp-host","sh","-s","--","/root/.config/impz/token","/proc"]
        ["exec","-e","HOME=/root","imp-host","impz","image","ls","--json"]
        ["exec","-e","HOME=/root","imp-host","impz","image","add","ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}","--name","pv-base","--json"]
        ["exec","-e","HOME=/root","imp-host","impz","image","pin","pv-base"]
        EOF
      '';
    }
    {
      title = "it keeps waiting when the token-file check fails after a refused call, and names the failure in the error";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 1 > impd/unauthorized
        echo 'Error: no container with name or ID "imp-host" found: no such container' > impd/script-error

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equal "$status" 0
        # the error
        assert_equal "$(cat err)" 'preview-image: try 1: impz: unauthorized: set IMP_TOKEN to the token from <IMP_DATA_DIR>/token, or run impz login <url>; the token-file check failed: Error: no container with name or ID "imp-host" found: no such container'
        # impd's images
        assert_equal "$(jq -c 'map([.name, .pinned])' impd/images.json)" '[["pv-base",true]]'
      '';
    }
    {
      title = "it leaves out an impd process whose stat line is gone or empty by the token-file check, and keeps waiting";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 1 > impd/unauthorized
        mkdir -p impd/container/var/lib/imp impd/container/root/.config/impz impd/container/proc/4242 impd/container/proc/4343
        printf 'imp_fixture_root\n' > impd/container/var/lib/imp/token
        touch -d @1793300070 impd/container/var/lib/imp/token
        ln -s ../../../var/lib/imp/token impd/container/root/.config/impz/token
        printf 'btime 1793300000\n' > impd/container/proc/stat
        echo impd > impd/container/proc/4242/comm
        echo impd > impd/container/proc/4343/comm
        : > impd/container/proc/4343/stat
        inode=$(stat -c %i impd/container/var/lib/imp/token)

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equal "$status" 0
        # the error
        assert_equal "$(cat err)" "preview-image: try 1: impz: unauthorized: set IMP_TOKEN to the token from <IMP_DATA_DIR>/token, or run impz login <url>; impz's token file: inode $inode, modified 2026-10-29T18:54:30Z"
        # impd's images
        assert_equal "$(jq -c 'map([.name, .pinned])' impd/images.json)" '[["pv-base",true]]'
      '';
    }
    {
      title = "it waits for the impd /health to report ready before its first impz call, printing a changed answer once";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 2 > impd/starting

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equal "$status" 0
        # the error
        assert_equal "$(cat err)" 'preview-image: try 1: impd is not ready: /health answered {"status":"ok","ready":false,"warnings":[]}'
        diff -u - sleep.log <<'EOF'
        ["2"]
        ["2"]
        EOF
        diff -u - impd/calls <<'EOF'
        ["exec","imp-host","curl","-sS","--max-time","5","http://127.0.0.1:7070/health"]
        ["exec","imp-host","curl","-sS","--max-time","5","http://127.0.0.1:7070/health"]
        ["exec","imp-host","curl","-sS","--max-time","5","http://127.0.0.1:7070/health"]
        ["exec","-e","HOME=/root","imp-host","impz","image","ls","--json"]
        ["exec","-e","HOME=/root","imp-host","impz","image","add","ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}","--name","pv-base","--json"]
        ["exec","-e","HOME=/root","imp-host","impz","image","pin","pv-base"]
        EOF
      '';
    }
    {
      title = "it waits about 10 min for impd by default, 300 tries, before it fails";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 300 > impd/starting

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equal "$status" 1
        diff -u - err <<'EOF'
        preview-image: try 1: impd is not ready: /health answered {"status":"ok","ready":false,"warnings":[]}
        preview-image: impd listed no images after 300 tries: impd is not ready: /health answered {"status":"ok","ready":false,"warnings":[]}
        EOF
        # the pauses
        assert_equal "$(wc -l < sleep.log)" 299
        # the calls
        assert_equal "$(wc -l < impd/calls)" 300
      '';
    }
    {
      title = "it fails with the last podman error when impd does not answer in its tries";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 5 > impd/unreachable

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" PREVIEW_IMAGE_WAIT_TRIES=3 \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equal "$status" 1
        diff -u /dev/null out
        diff -u - err <<'EOF'
        preview-image: try 1: Error: no container with name or ID "imp-host" found: no such container
        preview-image: impd listed no images after 3 tries: Error: no container with name or ID "imp-host" found: no such container
        EOF
        diff -u - sleep.log <<'EOF'
        ["2"]
        ["2"]
        EOF
        # the calls
        assert_equal "$(wc -l < impd/calls)" 3
      '';
    }
    {
      title = "it fails with the impz error when the add fails";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 'image ghcr.io/example/imp-base:1.2.3: pull failed' > impd/add-error

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equal "$status" 1
        # the output
        assert_equal "$(cat out)" "preview-image: adding ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} to impd as pv-base"
        # the error
        assert_equal "$(cat err)" "impz: image ghcr.io/example/imp-base:1.2.3: pull failed"
        # impd's images
        assert_equal "$(cat impd/images.json)" '[]'
      '';
    }
    {
      title = "it packages the service modules without the tests, mocks or stand-ins";
      script = ''
        cat > expected <<'EOF'
        ./apply-slot-evictions.ts
        ./build-bun-pin-check.ts
        ./build-contract-imp-name.ts
        ./build-contract-status.ts
        ./build-forwarded-headers.ts
        ./build-github-client.ts
        ./build-imp-name.ts
        ./build-impd-client.ts
        ./build-spend-proxy-io.ts
        ./bun-release.ts
        ./contract-script.ts
        ./counting-proxy-config-schema.ts
        ./create-preview-store.ts
        ./create-spend-proxies.ts
        ./github-request-error.ts
        ./has-sdk-pin-change.ts
        ./load-preview-config.ts
        ./main.ts
        ./make-link-handler.ts
        ./make-slot-lock.ts
        ./make-spend-handler.ts
        ./make-webhook-handler.ts
        ./model-route.ts
        ./parse-preview-contract.ts
        ./parse-pull-request-event.ts
        ./pick-proxy-outcome.ts
        ./pick-spend-admission.ts
        ./plan-contract-evictions.ts
        ./plan-idle-sleeps.ts
        ./plan-slot-evictions.ts
        ./proxy-machine.ts
        ./render-preview-comment.ts
        ./render-preview-page.ts
        ./render-spend-refusal.ts
        ./run-contract-retries.ts
        ./run-contract-run.ts
        ./run-contract-suite.ts
        ./run-egress-update.ts
        ./run-idle-sweep.ts
        ./run-preview-boot.ts
        ./start-contract-run.ts
        ./start-preview-service.ts
        ./types.ts
        ./verify-webhook-signature.ts
        ./wait-for-healthy.ts
        EOF

        src=$(sed -n 's|^exec bun --no-install run \(/nix/store/[^ ]*\)/main\.ts$|\1|p' ${package}/bin/preview-service)
        (cd "$src" && find . -path ./node_modules -prune -o -type f -print | LC_ALL=C sort) > actual

        diff -u expected actual
      '';
    }
    {
      title = "it loads the typed impd client and its dependencies from the package, with installs off";
      script = ''
        src=$(sed -n 's|^exec bun --no-install run \(/nix/store/[^ ]*\)/main\.ts$|\1|p' ${package}/bin/preview-service)
        cat > load.ts <<EOF
        import { buildImpdClient } from '$src/build-impd-client.ts';

        console.log(Object.keys(buildImpdClient('http://127.0.0.1:1', 'imp_check.token')).join(' '));
        EOF

        HOME="$PWD" ${pkgs.bun}/bin/bun --no-install run load.ts > out 2> err

        # the client's calls
        assert_equal "$(cat out)" "createImp readImp readImps sleepImp wakeImp updateHTTPPort updatePublicEgress removeImp installGrant installPathGrant removeGrantsExcept runCommand"
        # bun's errors
        assert_equal "$(cat err)" ""
      '';
    }
  ];
in
pkgs.runCommand "preview-check"
  {
    nativeBuildInputs = [
      (pkgs.bats.withLibraries (p: [
        p.bats-support
        p.bats-assert
      ]))
      pkgs.diffutils
      pkgs.gnused
      pkgs.findutils
      pkgs.jq
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    bats --timing --print-output-on-failure ${pkgs.writeText "preview.bats" (renderCases cases)}
    touch $out
  ''
