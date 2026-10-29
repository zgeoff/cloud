# Checks services.agent-image-build: the units the module generates, and the build script run in the
# build sandbox against a local git origin, with the stand-in podman of
# test-utils/build-stub-imp-host-podman.nix for imp-host, the stand-in bun of
# test-utils/build-stub-agent-image-bun.nix for the build script's run, and the stand-in sleep of
# test-utils/build-stub-sleep.nix for its pauses, with 3 tries for impd. Each case runs on its own,
# in a fresh directory, with its own origin, impd state, credentials and state directory, and the
# script under env -i with a HOME and TMPDIR of its own, under test-support/shell/run-cases.sh.
# Run: bun run test:nixos agent-image-build
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };
  stubImpHostPodman = import ./test-utils/build-stub-imp-host-podman.nix { inherit pkgs; };
  stubAgentImageBun = import ./test-utils/build-stub-agent-image-bun.nix { inherit pkgs; };
  stubSleep = import ./test-utils/build-stub-sleep.nix { inherit pkgs; };

  enabled = {
    services.agent-image-build = {
      enable = true;
      impdURL = "http://127.0.0.1:7070";
      impTokenFile = "/var/lib/tank-cloud/host-secrets/agent-image-build/imp-token";
    };
  };

  build = "${(buildModuleSystem ../modules/agent-image-build.nix enabled).config.services.agent-image-build.package}/bin/agent-image-build";

  # The runtime every script case needs: its directories, an empty origin repository with a main
  # branch, git that reads no config outside the case and never starts its maintenance, and
  # run_build, which runs the script against the origin, the stand-ins and the case's state, and
  # records its exit status, stdout, stderr and the clock around it.
  setupTest = ''
    mkdir home tmp state impd build credentials origin
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME="Fixture Author" GIT_AUTHOR_EMAIL=author@example.com
    export GIT_COMMITTER_NAME="Fixture Author" GIT_COMMITTER_EMAIL=author@example.com
    git -C origin init -q -b main
    git -C origin config maintenance.auto false

    run_build() {
      before=$(date +%s)
      status=0
      env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
        REPO_URL="$PWD/origin" STATE_DIR="$PWD/state" IMP_URL=http://127.0.0.1:7070 \
        CREDENTIALS_DIRECTORY="$PWD/credentials" PODMAN=${stubImpHostPodman} IMPD_STATE="$PWD/impd" \
        BUN=${stubAgentImageBun} BUILD_STATE="$PWD/build" SLEEP=${stubSleep} SLEEP_LOG="$PWD/sleep.log" \
        AGENT_IMAGE_WAIT_TRIES=3 ${build} > stdout 2> stderr || status=$?
      after=$(date +%s)
    }
  '';

  cases = [
    {
      title = "it checks every 5 minutes as root, once the token file exists, and a switch leaves a running build alone";
      script =
        let
          config = (buildModuleSystem ../modules/agent-image-build.nix enabled).config;
          service = config.systemd.services.agent-image-build;
          timer = config.systemd.timers.agent-image-build;
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            service = {
              description = "agent image build from main";
              wantedBy = [ ];
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              restartIfChanged = false;
              unitConfig.ConditionPathExists = "/var/lib/tank-cloud/host-secrets/agent-image-build/imp-token";
              environment = {
                REPO_URL = "https://github.com/zgeoff/cloud.git";
                STATE_DIR = "/var/lib/agent-image-build";
                HOME = "/var/lib/agent-image-build";
                IMP_URL = "http://127.0.0.1:7070";
                # the podman module wraps pkgs.podman with the system's runtimes, so the unit runs
                # the system's own podman
                PODMAN = "${config.virtualisation.podman.package}/bin/podman";
                BUN = "${pkgs.bun}/bin/bun";
                BUN_RUNTIME_TRANSPILER_CACHE_PATH = "0";
              };
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${config.services.agent-image-build.package}/bin/agent-image-build";
                LoadCredential = [
                  "imp-token:/var/lib/tank-cloud/host-secrets/agent-image-build/imp-token"
                ];
                TimeoutStartSec = "2h";
                StateDirectory = "agent-image-build";
                StateDirectoryMode = "0700";
                BindReadOnlyPaths = [ "${pkgs.glibc}/lib/ld-linux-x86-64.so.2:/lib64/ld-linux-x86-64.so.2" ];
                NoNewPrivileges = true;
                ProtectSystem = "full";
                PrivateTmp = true;
              };
            };
            timer = {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnBootSec = "5min";
                OnUnitActiveSec = "5min";
                AccuracySec = "1min";
              };
            };
          }}
          EOF

          # NixOS adds PATH to every service's environment
          jq -S . > actual <<'EOF'
          ${builtins.toJSON {
            service = {
              inherit (service)
                description
                wantedBy
                after
                wants
                restartIfChanged
                serviceConfig
                ;
              unitConfig = { inherit (service.unitConfig) ConditionPathExists; };
              environment = removeAttrs service.environment [ "PATH" ];
            };
            timer = {
              inherit (timer) wantedBy timerConfig;
            };
          }}
          EOF

          assert_files_equal expected actual
        '';
    }
    {
      title = "it adds no unit when it is off";
      script =
        let
          config =
            (buildModuleSystem ../modules/agent-image-build.nix { services.agent-image-build.enable = false; })
            .config;
        in
        ''
          assert_equals '{"service":false,"timer":false}' ${
            lib.escapeShellArg (
              builtins.toJSON {
                service = config.systemd.services ? agent-image-build;
                timer = config.systemd.timers ? agent-image-build;
              }
            )
          } "what the module adds"
        '';
    }
    {
      title = "it builds the newest commit on main that changes images/agent, with the CLI from imp-host and the token in its environment";
      script = ''
        ${setupTest}
        mkdir -p origin/images/agent origin/docs impd/container/usr/local/bin
        echo 'ARG ATC_VERSION=1.0.0' > origin/images/agent/Dockerfile
        git -C origin add -A && git -C origin commit -q -m "pin atc 1.0.0"
        older=$(git -C origin rev-parse HEAD)
        echo 'ARG ATC_VERSION=1.1.0' > origin/images/agent/Dockerfile
        git -C origin add -A && git -C origin commit -q -m "pin atc 1.1.0"
        pin=$(git -C origin rev-parse HEAD)
        echo 'a note' > origin/docs/notes.md
        git -C origin add -A && git -C origin commit -q -m "add a note"
        head=$(git -C origin rev-parse HEAD)
        image="agent-$(git -C origin rev-parse --short "$pin")"
        jq -n --arg name "agent-$(git -C origin rev-parse --short "$older")" \
          '[{id: "img-1", name: $name, ref: "", digest: "imp-build-aa", source: "build", createdAt: "2026-01-01T00:00:00.000Z", sizeBytes: 0, pinned: true}]' > impd/images.json
        printf '#!/bin/sh\necho stand-in impz\n' > impd/container/usr/local/bin/impz
        chmod 0755 impd/container/usr/local/bin/impz
        printf 'imp_fixture_build_token' > credentials/imp-token
        echo "$image imp-build-cc check passed" > build/stdout

        run_build

        assert_equals 0 "$status" "the script's exit status"
        assert_files_equal - stdout <<EOF
        agent-image-build: building $image from $pin
        agent-image-build: $image imp-build-cc check passed
        EOF
        assert_files_equal /dev/null stderr
        jq -c . > expected <<EOF
        ["exec","imp-host","impz","image","ls","--json"]
        ["cp","imp-host:/usr/local/bin/impz","$PWD/state/bin/impz"]
        EOF
        assert_files_equal expected impd/calls
        jq -S . > expected <<EOF
        {
          "argv": ["scripts/build-agent-image.ts", "$pin"],
          "cwd": "$PWD/state/cloud",
          "impURL": "http://127.0.0.1:7070",
          "impToken": "imp_fixture_build_token",
          "impz": "$PWD/state/bin/impz"
        }
        EOF
        jq -S . build/calls > actual
        assert_files_equal expected actual
        assert_files_equal impd/container/usr/local/bin/impz state/bin/impz
        assert_equals "$head" "$(git -C state/cloud rev-parse HEAD)" "the commit the build runs from"
        assert_missing state/failed "the failed builds"
      '';
    }
    {
      title = "it builds a commit that lands on main after an earlier run, from the clone it keeps";
      script = ''
        ${setupTest}
        mkdir -p origin/images/agent impd/container/usr/local/bin
        echo 'ARG ATC_VERSION=1.0.0' > origin/images/agent/Dockerfile
        git -C origin add -A && git -C origin commit -q -m "pin atc 1.0.0"
        jq -n --arg name "agent-$(git -C origin rev-parse --short HEAD)" \
          '[{id: "img-1", name: $name, ref: "", digest: "imp-build-aa", source: "build", createdAt: "2026-01-01T00:00:00.000Z", sizeBytes: 0, pinned: true}]' > impd/images.json
        printf '#!/bin/sh\n' > impd/container/usr/local/bin/impz
        printf 'imp_fixture_build_token' > credentials/imp-token
        run_build
        assert_equals 0 "$status" "the earlier run's exit status"
        echo 'ARG ATC_VERSION=1.1.0' > origin/images/agent/Dockerfile
        git -C origin add -A && git -C origin commit -q -m "pin atc 1.1.0"
        pin=$(git -C origin rev-parse HEAD)
        image="agent-$(git -C origin rev-parse --short "$pin")"
        echo "$image imp-build-cc check passed" > build/stdout

        run_build

        assert_equals 0 "$status" "the script's exit status"
        assert_files_equal - stdout <<EOF
        agent-image-build: building $image from $pin
        agent-image-build: $image imp-build-cc check passed
        EOF
        assert_files_equal /dev/null stderr
        assert_equals "[\"scripts/build-agent-image.ts\",\"$pin\"]" "$(jq -c .argv build/calls)" "the build's argv"
      '';
    }
    {
      title = "it builds nothing when impd holds the image of the newest commit that changes images/agent";
      script = ''
        ${setupTest}
        mkdir -p origin/images/agent origin/docs
        echo 'ARG ATC_VERSION=1.0.0' > origin/images/agent/Dockerfile
        git -C origin add -A && git -C origin commit -q -m "pin atc 1.0.0"
        pin=$(git -C origin rev-parse HEAD)
        echo 'a note' > origin/docs/notes.md
        git -C origin add -A && git -C origin commit -q -m "add a note"
        image="agent-$(git -C origin rev-parse --short "$pin")"
        jq -n --arg name "$image" \
          '[{id: "img-1", name: $name, ref: "", digest: "imp-build-aa", source: "build", createdAt: "2026-01-01T00:00:00.000Z", sizeBytes: 0, pinned: true}]' > impd/images.json
        printf 'imp_fixture_build_token' > credentials/imp-token

        run_build

        assert_equals 0 "$status" "the script's exit status"
        assert_equals "agent-image-build: impd holds $image, built from $pin; nothing to build" "$(cat stdout)" "the script's stdout"
        assert_files_equal /dev/null stderr
        assert_equals '["exec","imp-host","impz","image","ls","--json"]' "$(cat impd/calls)" "the podman calls"
        assert_missing build/calls "the build calls"
        assert_missing state/bin "the copied CLI"
      '';
    }
    {
      title = "it builds nothing and calls no podman when no commit on main changes images/agent";
      script = ''
        ${setupTest}
        mkdir -p origin/docs
        echo 'a note' > origin/docs/notes.md
        git -C origin add -A && git -C origin commit -q -m "add a note"
        echo '[]' > impd/images.json
        printf 'imp_fixture_build_token' > credentials/imp-token

        run_build

        assert_equals 0 "$status" "the script's exit status"
        assert_equals "agent-image-build: no commit on main changes images/agent; nothing to build" "$(cat stdout)" "the script's stdout"
        assert_files_equal /dev/null stderr
        assert_missing impd/calls "the podman calls"
        assert_missing build/calls "the build calls"
      '';
    }
    {
      title = "it records a failed build with its time, and fails the run";
      script = ''
        ${setupTest}
        mkdir -p origin/images/agent impd/container/usr/local/bin
        echo 'ARG ATC_VERSION=1.0.0' > origin/images/agent/Dockerfile
        git -C origin add -A && git -C origin commit -q -m "pin atc 1.0.0"
        pin=$(git -C origin rev-parse HEAD)
        image="agent-$(git -C origin rev-parse --short "$pin")"
        echo '[]' > impd/images.json
        printf '#!/bin/sh\n' > impd/container/usr/local/bin/impz
        printf 'imp_fixture_build_token' > credentials/imp-token
        echo "$image check failed; removed the image" > build/stdout
        echo 1 > build/status

        run_build

        assert_equals 1 "$status" "the script's exit status"
        assert_equals "agent-image-build: building $image from $pin" "$(cat stdout)" "the script's stdout"
        assert_equals "agent-image-build: the build of $image from $pin failed with status 1: $image check failed; removed the image; remove $PWD/state/failed/$pin to build it again" \
          "$(cat stderr)" "the script's stderr"
        assert_between "$before" "$(date -u -d "$(cat "state/failed/$pin")" +%s)" "$after" "the failed build's time"
        assert_equals "$pin" "$(ls state/failed)" "the failed builds"
      '';
    }
    {
      title = "it builds nothing for a commit whose build failed before, and names the file to remove";
      script = ''
        ${setupTest}
        mkdir -p origin/images/agent state/failed
        echo 'ARG ATC_VERSION=1.0.0' > origin/images/agent/Dockerfile
        git -C origin add -A && git -C origin commit -q -m "pin atc 1.0.0"
        pin=$(git -C origin rev-parse HEAD)
        image="agent-$(git -C origin rev-parse --short "$pin")"
        echo '[]' > impd/images.json
        printf 'imp_fixture_build_token' > credentials/imp-token
        echo 2026-01-02T03:04:05Z > "state/failed/$pin"

        run_build

        assert_equals 0 "$status" "the script's exit status"
        assert_equals "agent-image-build: the build of $image from $pin failed at 2026-01-02T03:04:05Z; remove $PWD/state/failed/$pin to build it again" \
          "$(cat stdout)" "the script's stdout"
        assert_files_equal /dev/null stderr
        assert_missing impd/calls "the podman calls"
        assert_missing build/calls "the build calls"
      '';
    }
    {
      title = "it waits while imp-host is missing and then while impd refuses the call, printing each new error, then checks the images";
      script = ''
        ${setupTest}
        mkdir -p origin/images/agent
        echo 'ARG ATC_VERSION=1.0.0' > origin/images/agent/Dockerfile
        git -C origin add -A && git -C origin commit -q -m "pin atc 1.0.0"
        pin=$(git -C origin rev-parse HEAD)
        image="agent-$(git -C origin rev-parse --short "$pin")"
        jq -n --arg name "$image" \
          '[{id: "img-1", name: $name, ref: "", digest: "imp-build-aa", source: "build", createdAt: "2026-01-01T00:00:00.000Z", sizeBytes: 0, pinned: true}]' > impd/images.json
        echo 1 > impd/unreachable
        echo 1 > impd/unauthorized
        printf 'imp_fixture_build_token' > credentials/imp-token

        run_build

        assert_equals 0 "$status" "the script's exit status"
        assert_files_equal - stdout <<EOF
        agent-image-build: waiting for impd, try 1: Error: no container with name or ID "imp-host" found: no such container
        agent-image-build: waiting for impd, try 2: impz: unauthorized: set IMP_TOKEN to the token from <IMP_DATA_DIR>/token, or run impz login <url>
        agent-image-build: impd holds $image, built from $pin; nothing to build
        EOF
        assert_files_equal /dev/null stderr
        assert_files_equal - sleep.log <<'EOF'
        ["5"]
        ["5"]
        EOF
        assert_missing build/calls "the build calls"
      '';
    }
    {
      title = "it skips the run without a record or a build when imp-host does not answer in its tries";
      script = ''
        ${setupTest}
        mkdir -p origin/images/agent
        echo 'ARG ATC_VERSION=1.0.0' > origin/images/agent/Dockerfile
        git -C origin add -A && git -C origin commit -q -m "pin atc 1.0.0"
        echo '[]' > impd/images.json
        echo 3 > impd/unreachable
        printf 'imp_fixture_build_token' > credentials/imp-token

        run_build

        assert_equals 0 "$status" "the script's exit status"
        assert_files_equal - stdout <<'EOF'
        agent-image-build: waiting for impd, try 1: Error: no container with name or ID "imp-host" found: no such container
        agent-image-build: impd listed no images after 3 tries: Error: no container with name or ID "imp-host" found: no such container; the next run tries again
        EOF
        assert_files_equal /dev/null stderr
        assert_equals 3 "$(wc -l < impd/calls)" "the podman calls"
        assert_equals 2 "$(wc -l < sleep.log)" "the pauses"
        assert_missing build/calls "the build calls"
        assert_missing state/failed "the failed builds"
      '';
    }
  ];
in
pkgs.runCommand "agent-image-build-check"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.git
      pkgs.jq
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    # fixed, so the modes the cases assert do not depend on the builder's umask
    umask 022
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${testLib}/assert-files-equal.sh
    source ${testLib}/assert-between.sh
    source ${testLib}/assert-missing.sh
    source ${pkgs.writeText "agent-image-build-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
