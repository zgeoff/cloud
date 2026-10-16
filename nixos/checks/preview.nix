# Evaluates services.preview apart from any host's config and checks the units it defines, runs
# the preview-image unit's script against a stand-in docker that answers for impd
# (test-utils/build-stub-imp-host-docker.nix) and a stand-in sleep (test-utils/build-stub-sleep.nix),
# and builds the package to check that it carries the service's modules and none of its tests.
# Each case runs on its own, in a fresh directory, under test-support/shell/run-cases.sh.
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
  stubImpHostDocker = import ./test-utils/build-stub-imp-host-docker.nix { inherit pkgs; };
  stubSleep = import ./test-utils/build-stub-sleep.nix { inherit pkgs; };

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
        githubTokenFile = "/run/fixture/github-token";
        impTokenFile = "/run/fixture/imp-token";
      }
      // imageSettings;
    };
  imageScript =
    lib.getExe
      (buildImageSystem {
        impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
      }).config.services.preview.imageScript;

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
              "preview-image.service"
            ];
            wants = [
              "network-online.target"
              "preview-image.service"
            ];
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
              PREVIEW_IMP_IMAGE = "pv-base";
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
              impRegistryImage = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
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
      title = "it sets the contract run's repositories, model secret and time limit once contractRepos lists a repository";
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
              webhookSecretFile = "/run/fixture/webhook-secret";
              githubTokenFile = "/run/fixture/github-token";
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
          }}
          EOF

          jq -S . > actual <<'EOF'
          ${builtins.toJSON {
            inherit (environment)
              PREVIEW_CONTRACT_REPOS
              PREVIEW_CONTRACT_MODEL_SECRET
              PREVIEW_CONTRACT_TIMEOUT_MINUTES
              ;
          }}
          EOF

          assert_files_equal expected actual
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it leaves the contract run's settings out when contractRepos is empty";
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
              githubTokenFile = "/run/fixture/github-token";
              impTokenFile = "/run/fixture/imp-token";
            };
          };
          names = builtins.attrNames system.config.systemd.services.preview.environment;
        in
        ''
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (builtins.filter (lib.hasPrefix "PREVIEW_CONTRACT_") names))} "the contract run's variables"
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
              githubTokenFile = "/run/fixture/github-token";
              impTokenFile = "/run/fixture/imp-token";
            };
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "services.preview.contractModelSecret must name the model secret when contractRepos lists a repository."
              ]
            )
          } ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it adds the pinned image to impd once imp-host runs, at each switch that changes the pin and each imp-host restart, before the service starts";
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
            environment = {
              PREVIEW_IMAGE_NAME = "pv-base";
              PREVIEW_IMAGE_REF = "ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}";
            };
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = imageScript;
              TimeoutStartSec = "20min";
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
              serviceConfig
              ;
            environment = removeAttrs service.environment [ "PATH" ];
          }}
          EOF

          assert_files_equal expected actual
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
          assert_equals pv-sandbox ${lib.escapeShellArg environments.preview-image.PREVIEW_IMAGE_NAME} "the name the unit adds"
          assert_equals pv-sandbox ${lib.escapeShellArg environments.preview.PREVIEW_IMP_IMAGE} "the name the service boots"
        '';
    }
    {
      title = "it refuses an image reference that no digest pins";
      script = ''
        assert_equals false ${
          lib.boolToString
            (builtins.tryEval
              (buildImageSystem { impRegistryImage = "ghcr.io/example/imp-base:1.2.3"; })
              .config.systemd.services.preview-image.environment.PREVIEW_IMAGE_REF
            ).success
        } "whether it evaluated"
      '';
    }
    {
      title = "it adds the pinned image under the preview image name when impd holds no image of that name, and leaves the other impd images alone";
      script = ''
        mkdir home tmp impd
        echo '[{"id":"img-1","name":"base","ref":"ghcr.io/example/imp-base:1.0.0","digest":"imp-build-aa","source":"oci","createdAt":"2026-02-03T04:05:06.000Z","sizeBytes":12}]' > impd/images.json

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" DOCKER=${stubImpHostDocker} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equals 0 "$status" "the exit status"
        assert_files_equal - out <<'EOF'
        preview-image: adding ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} to impd as pv-base
        preview-image: impd holds pv-base at ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}
        EOF
        assert_files_equal /dev/null err
        assert_files_equal - impd/calls <<'EOF'
        ["exec","imp-host","impz","image","ls","--json"]
        ["exec","imp-host","impz","image","add","ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}","--name","pv-base","--json"]
        EOF
        assert_equals '[["base","ghcr.io/example/imp-base:1.0.0"],["pv-base","ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}"]]' \
          "$(jq -c 'map([.name, .ref])' impd/images.json)" "impd's images"
        assert_missing sleep.log "the pauses"
      '';
    }
    {
      title = "it points the name at the pinned image in place of an older pin";
      script = ''
        mkdir home tmp impd
        echo '[{"id":"img-2","name":"pv-base","ref":"ghcr.io/example/imp-base:1.2.2@sha256:${lib.strings.replicate 64 "b"}","digest":"imp-build-bb","source":"oci","createdAt":"2026-02-03T04:05:06.000Z","sizeBytes":12}]' > impd/images.json

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" DOCKER=${stubImpHostDocker} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equals 0 "$status" "the exit status"
        assert_files_equal - out <<'EOF'
        preview-image: adding ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} to impd as pv-base, in place of ghcr.io/example/imp-base:1.2.2@sha256:${lib.strings.replicate 64 "b"}
        preview-image: impd holds pv-base at ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}
        EOF
        assert_files_equal /dev/null err
        assert_equals '[["pv-base","ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}"]]' \
          "$(jq -c 'map([.name, .ref])' impd/images.json)" "impd's images"
      '';
    }
    {
      title = "it adds nothing when the name already holds the pinned image";
      script = ''
        mkdir home tmp impd
        echo '[{"id":"img-3","name":"pv-base","ref":"ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}","digest":"imp-build-cc","source":"oci","createdAt":"2026-02-03T04:05:06.000Z","sizeBytes":12}]' > impd/images.json
        cp impd/images.json before.json

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" DOCKER=${stubImpHostDocker} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equals 0 "$status" "the exit status"
        assert_equals "preview-image: impd holds pv-base at ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}" "$(cat out)" "the output"
        assert_files_equal /dev/null err
        assert_equals '["exec","imp-host","impz","image","ls","--json"]' "$(cat impd/calls)" "the calls"
        assert_files_equal before.json impd/images.json
      '';
    }
    {
      title = "it waits for impd to answer, pausing between tries, before it adds the image";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 2 > impd/unreachable

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" DOCKER=${stubImpHostDocker} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equals 0 "$status" "the exit status"
        assert_files_equal /dev/null err
        assert_files_equal - sleep.log <<'EOF'
        ["2"]
        ["2"]
        EOF
        assert_files_equal - impd/calls <<'EOF'
        ["exec","imp-host","impz","image","ls","--json"]
        ["exec","imp-host","impz","image","ls","--json"]
        ["exec","imp-host","impz","image","ls","--json"]
        ["exec","imp-host","impz","image","add","ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"}","--name","pv-base","--json"]
        EOF
      '';
    }
    {
      title = "it fails with the last docker error when impd does not answer in its tries";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 5 > impd/unreachable

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" DOCKER=${stubImpHostDocker} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" PREVIEW_IMAGE_WAIT_TRIES=3 \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equals 1 "$status" "the exit status"
        assert_files_equal /dev/null out
        assert_equals "preview-image: impd listed no images after 3 tries: Error response from daemon: No such container: imp-host" "$(cat err)" "the error"
        assert_files_equal - sleep.log <<'EOF'
        ["2"]
        ["2"]
        EOF
        assert_equals 3 "$(wc -l < impd/calls)" "the calls"
      '';
    }
    {
      title = "it fails with the impz error when the add fails";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 'image ghcr.io/example/imp-base:1.2.3: pull failed' > impd/add-error

        status=0
        env -i HOME="$PWD/home" TMPDIR="$PWD/tmp" DOCKER=${stubImpHostDocker} IMPD_STATE="$PWD/impd" \
          SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
          PREVIEW_IMAGE_NAME=pv-base PREVIEW_IMAGE_REF=ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} \
          ${imageScript} > out 2> err || status=$?

        assert_equals 1 "$status" "the exit status"
        assert_equals "preview-image: adding ghcr.io/example/imp-base:1.2.3@sha256:${lib.strings.replicate 64 "c"} to impd as pv-base" "$(cat out)" "the output"
        assert_equals "impz: image ghcr.io/example/imp-base:1.2.3: pull failed" "$(cat err)" "the error"
        assert_equals '[]' "$(cat impd/images.json)" "impd's images"
      '';
    }
    {
      title = "it packages the service modules without the tests, mocks or stand-ins";
      script = ''
        cat > expected <<'EOF'
        ./apply-slot-evictions.ts
        ./build-contract-imp-name.ts
        ./build-contract-status.ts
        ./build-github-client.ts
        ./build-imp-name.ts
        ./build-impd-client.ts
        ./create-preview-store.ts
        ./has-sdk-pin-change.ts
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
        ./run-contract-retries.ts
        ./run-contract-run.ts
        ./run-idle-sweep.ts
        ./run-preview-boot.ts
        ./start-contract-run.ts
        ./start-preview-service.ts
        ./types.ts
        ./verify-webhook-signature.ts
        ./wait-for-healthy.ts
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
    source ${testLib}/assert-missing.sh
    source ${pkgs.writeText "preview-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
