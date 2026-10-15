# Evaluates services.preview apart from any host's config and checks the service it defines, and
# builds the package to check that it carries the service's modules and none of its tests. Each
# case runs on its own, in a fresh directory, under test-support/shell/run-cases.sh.
# Run: bun run test:nixos preview
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };
  collectFailedAssertions = import ./test-utils/collect-failed-assertions.nix;
  package = pkgs.callPackage ../packages/preview.nix { };

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
              impGitHubSecret = "gh";
              webhookSecretFile = "/run/fixture/webhook-secret";
              githubTokenFile = "/run/fixture/github-token";
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
            ];
            wants = [ "network-online.target" ];
            unitConfig.ConditionPathExists = [
              "/run/fixture/webhook-secret"
              "/run/fixture/github-token"
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
              PREVIEW_IMP_IMAGE = "base";
              PREVIEW_IMP_MEMORY_MIB = "4096";
              PREVIEW_IMP_GITHUB_SECRET = "gh";
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
                "github-token:/run/fixture/github-token"
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

          assert_files_equal expected actual
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it leaves the GitHub grant out when impGitHubSecret is null";
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
              webhookSecretFile = "/run/fixture/webhook-secret";
              githubTokenFile = "/run/fixture/github-token";
              impTokenFile = "/run/fixture/imp-token";
            };
          };
        in
        ''
          assert_equals false ${
            lib.boolToString (system.config.systemd.services.preview.environment ? PREVIEW_IMP_GITHUB_SECRET)
          } "the grant's variable is set"
        '';
    }
    {
      title = "it packages the service modules without the tests, mocks or stand-ins";
      script = ''
        cat > expected <<'EOF'
        ./apply-slot-evictions.ts
        ./build-github-client.ts
        ./build-imp-name.ts
        ./build-impd-client.ts
        ./create-preview-store.ts
        ./load-preview-config.ts
        ./main.ts
        ./make-link-handler.ts
        ./make-slot-lock.ts
        ./make-webhook-handler.ts
        ./parse-preview-contract.ts
        ./parse-pull-request-event.ts
        ./plan-idle-sleeps.ts
        ./plan-slot-evictions.ts
        ./render-preview-comment.ts
        ./render-preview-page.ts
        ./run-idle-sweep.ts
        ./run-preview-boot.ts
        ./start-preview-service.ts
        ./types.ts
        ./verify-webhook-signature.ts
        EOF

        src=$(sed -n 's|^exec bun run \(/nix/store/[^ ]*\)/main\.ts$|\1|p' ${package}/bin/preview-service)
        (cd "$src" && find . -type f | LC_ALL=C sort) > actual

        assert_files_equal expected actual
      '';
    }
  ];
in
pkgs.runCommand "preview-check"
  {
    nativeBuildInputs = [
      pkgs.diffutils
      pkgs.gnused
      pkgs.findutils
      pkgs.jq
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${testLib}/assert-files-equal.sh
    source ${pkgs.writeText "preview-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
