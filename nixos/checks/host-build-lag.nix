# Checks services.host-build-lag: the units the module generates, and the check script run in the
# build sandbox against Python's http.server, which serves a case's own GitHub answers from a
# directory on an ephemeral loopback port, with the stand-in docker of
# test-utils/build-stub-imp-host-docker.nix for imp-host. Each case runs on its own, in a fresh
# directory, with its own answers, state, textfile directory and current system, and the script
# under env -i with a HOME and TMPDIR of its own, under test-support/shell/run-cases.sh.
# Run: bun run test:nixos host-build-lag
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };
  stubImpHostDocker = import ./test-utils/build-stub-imp-host-docker.nix { inherit pkgs; };

  check = "${
    (buildModuleSystem ../modules/host-build-lag.nix { services.host-build-lag.enable = true; })
    .config.services.host-build-lag.package
  }/bin/host-build-lag";

  # The runtime every script case needs: its directories, the answers directory that
  # http.server serves, started on an ephemeral port that it prints first, and run_check, which
  # runs the check against it with the case's state and current system and records its exit
  # status, stdout, stderr and the clock around it.
  setupTest = ''
    mkdir home tmp out state impd www
    mkfifo port.fifo
    exec 3<>port.fifo
    (cd www && exec env -i PATH="$PATH" HOME="$PWD/../home" TMPDIR="$PWD/../tmp" \
      python3 -u -m http.server 0 --bind 127.0.0.1 > ../port.fifo 2> ../server.log) &
    server_pid=$!
    trap 'kill "$server_pid"' EXIT
    read -r -t 5 -u 3 banner
    port=$(sed -n 's/^Serving HTTP on 127\.0\.0\.1 port \([0-9]*\) .*/\1/p' <<< "$banner")

    run_check() {
      before=$(date +%s)
      status=0
      env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" REPO=example/cloud TEXTFILE_DIR=out \
        STATE_DIR="$PWD/state" CURRENT_SYSTEM="$PWD/current-system" \
        GITHUB_API_URL="http://127.0.0.1:$port" GITHUB_RAW_URL="http://127.0.0.1:$port/raw" \
        DOCKER=${stubImpHostDocker} IMPD_STATE="$PWD/impd" ${check} > stdout 2> stderr || status=$?
      after=$(date +%s)
      sed -n 's/.*"GET \([^ ]*\) HTTP\/1\.[01]" .*/\1/p' server.log > requests
    }
  '';

  running = "1111111111111111111111111111111111111111";
  green = "2222222222222222222222222222222222222222";
  runsPath = "/repos/example/cloud/actions/workflows/nixos-checks.yml/runs";
  runsRequest = "${runsPath}?branch=main&status=success&per_page=100";
  comparePath = "/repos/example/cloud/compare/${running}...${green}";
  configPath = "/raw/example/cloud/${green}/nixos/hosts/geoffcloud/configuration.nix";

  # the latest green run on main follows a newer pull request run, as GitHub lists them, newest first
  runs = builtins.toJSON {
    workflow_runs = [
      {
        head_sha = "3333333333333333333333333333333333333333";
        event = "pull_request";
      }
      {
        head_sha = green;
        event = "schedule";
      }
      {
        head_sha = running;
        event = "workflow_dispatch";
      }
    ];
  };
  greenConfig = ''image = "ghcr.io/zgeoff/imp-host:2.3.0@sha256:0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0";'';

  # writes the case's GitHub answers: the runs, the green commit's host config, and, when given,
  # the comparison of the running commit with the green one
  writeGitHub = comparison: ''
    mkdir -p "www$(dirname ${runsPath})" "www$(dirname ${comparePath})" "www$(dirname ${configPath})"
    cat > "www${runsPath}" <<'EOF'
    ${runs}
    EOF
    cat > "www${configPath}" <<'EOF'
    ${greenConfig}
    EOF
    ${lib.optionalString (comparison != null) ''
      cat > "www${comparePath}" <<'EOF'
      ${builtins.toJSON comparison}
      EOF
    ''}
  '';

  metrics =
    system: imp:
    lib.removeSuffix "\n" ''
      # HELP host_build_lag_seconds How long the host has run an older part than the latest green main build, 0 when it runs that build's.
      # TYPE host_build_lag_seconds gauge
      host_build_lag_seconds{part="system"} ${system}
      host_build_lag_seconds{part="imp"} ${imp}
      # HELP host_build_lag_last_check_timestamp_seconds When the last check ran.
      # TYPE host_build_lag_last_check_timestamp_seconds gauge
      host_build_lag_last_check_timestamp_seconds STAMP
    '';

  # bounds the check's own timestamp with assert_between, then masks it in a copy, actual
  maskMetrics = ''
    stamp=$(sed -n 's/^host_build_lag_last_check_timestamp_seconds //p' out/host_build_lag.prom)
    assert_between "$before" "$stamp" "$after" "the check's timestamp"
    sed "s/^host_build_lag_last_check_timestamp_seconds $stamp\$/host_build_lag_last_check_timestamp_seconds STAMP/" \
      out/host_build_lag.prom > actual
  '';

  cases = [
    {
      title = "it checks every hour as root, with the state directory and the GitHub hosts of the repo, by default";
      script =
        let
          config =
            (buildModuleSystem ../modules/host-build-lag.nix { services.host-build-lag.enable = true; }).config;
          service = config.systemd.services.host-build-lag;
          timer = config.systemd.timers.host-build-lag;
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            service = {
              description = "host build lag textfile metric";
              wantedBy = [ ];
              environment = {
                REPO = "zgeoff/cloud";
                TEXTFILE_DIR = "/var/lib/node-exporter/textfile";
                STATE_DIR = "/var/lib/host-build-lag";
                CURRENT_SYSTEM = "/run/current-system";
                GITHUB_API_URL = "https://api.github.com";
                GITHUB_RAW_URL = "https://raw.githubusercontent.com";
                DOCKER = "${pkgs.docker}/bin/docker";
              };
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${config.services.host-build-lag.package}/bin/host-build-lag";
                StateDirectory = "host-build-lag";
                NoNewPrivileges = true;
                ProtectSystem = "full";
                PrivateTmp = true;
              };
            };
            timer = {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnBootSec = "5min";
                OnUnitActiveSec = "1h";
                AccuracySec = "1min";
              };
            };
          }}
          EOF

          # NixOS adds PATH to every service's environment
          jq -S . > actual <<'EOF'
          ${builtins.toJSON {
            service = {
              inherit (service) description wantedBy serviceConfig;
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
            (buildModuleSystem ../modules/host-build-lag.nix { services.host-build-lag.enable = false; })
            .config;
        in
        ''
          assert_equals '{"service":false,"timer":false}' ${
            lib.escapeShellArg (
              builtins.toJSON {
                service = config.systemd.services ? host-build-lag;
                timer = config.systemd.timers ? host-build-lag;
              }
            )
          } "what the module adds"
        '';
    }
    {
      title = "it reports the lag since the first check that saw it, for a host that runs an older system and imp";
      script = ''
        ${setupTest}
        ${writeGitHub {
          status = "ahead";
          files = [
            { filename = "docs/runbooks/workflows.md"; }
            { filename = "nixos/hosts/geoffcloud/configuration.nix"; }
          ];
        }}
        mkdir -p store/aaaa-nixos-system-geoffcloud
        ln -s "$PWD/store/aaaa-nixos-system-geoffcloud" current-system
        echo "${running} $PWD/store/aaaa-nixos-system-geoffcloud" > state/switches
        echo 2.2.1 > impd/version
        arranged=$(date +%s)
        since=$((arranged - 90000))
        echo "$PWD/store/aaaa-nixos-system-geoffcloud $since" > state/system-lag
        echo "2.2.1 $since" > state/imp-lag

        run_check

        assert_equals 0 "$status" "the check's exit status"
        assert_files_equal /dev/null stdout
        assert_files_equal /dev/null stderr
        assert_files_equal - requests <<'EOF'
        ${runsRequest}
        ${comparePath}
        ${configPath}
        EOF
        ${maskMetrics}
        system_lag=$(sed -n 's/^host_build_lag_seconds{part="system"} //p' actual)
        imp_lag=$(sed -n 's/^host_build_lag_seconds{part="imp"} //p' actual)
        assert_between 90000 "$system_lag" "$((90000 + after - arranged))" "the system's lag"
        assert_between 90000 "$imp_lag" "$((90000 + after - arranged))" "imp's lag"
        sed -i -e "s/^\(host_build_lag_seconds{part=\"system\"}\) $system_lag\$/\1 LAG/" \
          -e "s/^\(host_build_lag_seconds{part=\"imp\"}\) $imp_lag\$/\1 LAG/" actual
        assert_files_equal - actual <<'EOF'
        ${metrics "LAG" "LAG"}
        EOF
        assert_equals 644 "$(stat -c %a out/host_build_lag.prom)" "the file's mode"
        assert_equals host_build_lag.prom "$(ls -A out)" "the textfile directory"
        assert_equals "$PWD/store/aaaa-nixos-system-geoffcloud $since" "$(cat state/system-lag)" "the system's lag state"
        assert_equals "2.2.1 $since" "$(cat state/imp-lag)" "imp's lag state"
      '';
    }
    {
      title = "it reports no lag and drops the lag state for a host that runs the latest green build";
      script = ''
        ${setupTest}
        ${writeGitHub null}
        mkdir -p store/bbbb-nixos-system-geoffcloud
        ln -s "$PWD/store/bbbb-nixos-system-geoffcloud" current-system
        printf '%s\n' "${running} $PWD/store/aaaa-nixos-system-geoffcloud" \
          "${green} $PWD/store/bbbb-nixos-system-geoffcloud" > state/switches
        echo 2.3.0 > impd/version
        echo "$PWD/store/aaaa-nixos-system-geoffcloud 1000" > state/system-lag
        echo "2.2.1 1000" > state/imp-lag

        run_check

        assert_equals 0 "$status" "the check's exit status"
        assert_files_equal /dev/null stdout
        assert_files_equal /dev/null stderr
        assert_files_equal - requests <<'EOF'
        ${runsRequest}
        ${configPath}
        EOF
        ${maskMetrics}
        assert_files_equal - actual <<'EOF'
        ${metrics "0" "0"}
        EOF
        assert_equals switches "$(ls -A state)" "the state directory"
        assert_equals '["exec","imp-host","impz","info"]' "$(cat impd/calls)" "the docker calls"
      '';
    }
    {
      title = "it starts the lag at 0 when it first sees the host run an older build, and keeps the time";
      script = ''
        ${setupTest}
        ${writeGitHub {
          status = "ahead";
          files = [ { filename = "packages/topology/topology.json"; } ];
        }}
        mkdir -p store/aaaa-nixos-system-geoffcloud
        ln -s "$PWD/store/aaaa-nixos-system-geoffcloud" current-system
        echo "${running} $PWD/store/aaaa-nixos-system-geoffcloud" > state/switches
        echo 2.2.1 > impd/version
        echo "2.2.0 1000" > state/imp-lag

        run_check

        assert_equals 0 "$status" "the check's exit status"
        assert_files_equal /dev/null stdout
        assert_files_equal /dev/null stderr
        ${maskMetrics}
        assert_files_equal - actual <<'EOF'
        ${metrics "0" "0"}
        EOF
        read -r system_running system_since < state/system-lag
        read -r imp_running imp_since < state/imp-lag
        assert_equals "$PWD/store/aaaa-nixos-system-geoffcloud" "$system_running" "the system the lag state names"
        assert_equals "$stamp" "$system_since" "the system's lag start"
        assert_equals 2.2.1 "$imp_running" "the imp the lag state names"
        assert_equals "$stamp" "$imp_since" "imp's lag start"
      '';
    }
    {
      title = "it reports no system lag when the newer green commit changes no file the system is built from";
      script = ''
        ${setupTest}
        ${writeGitHub {
          status = "ahead";
          files = [
            { filename = "docs/runbooks/workflows.md"; }
            { filename = "nixos/checks/preview.nix"; }
            { filename = "infra/index.ts"; }
            { filename = "infra/Pulumi.prod.yaml"; }
            { filename = "scripts/alert-prod-apply.sh"; }
          ];
        }}
        mkdir -p store/aaaa-nixos-system-geoffcloud
        ln -s "$PWD/store/aaaa-nixos-system-geoffcloud" current-system
        echo "${running} $PWD/store/aaaa-nixos-system-geoffcloud" > state/switches
        echo 2.3.0 > impd/version

        run_check

        assert_equals 0 "$status" "the check's exit status"
        assert_files_equal /dev/null stderr
        assert_files_equal - requests <<'EOF'
        ${runsRequest}
        ${comparePath}
        ${configPath}
        EOF
        ${maskMetrics}
        assert_files_equal - actual <<'EOF'
        ${metrics "0" "0"}
        EOF
        assert_equals switches "$(ls -A state)" "the state directory"
      '';
    }
    {
      title = "it counts a system file renamed away by the newer green commit as a change";
      script = ''
        ${setupTest}
        ${writeGitHub {
          status = "ahead";
          files = [
            {
              filename = "docs/old-module.md";
              previous_filename = "nixos/modules/old-module.nix";
            }
          ];
        }}
        mkdir -p store/aaaa-nixos-system-geoffcloud
        ln -s "$PWD/store/aaaa-nixos-system-geoffcloud" current-system
        echo "${running} $PWD/store/aaaa-nixos-system-geoffcloud" > state/switches
        echo 2.3.0 > impd/version

        run_check

        assert_equals 0 "$status" "the check's exit status"
        assert_files_equal /dev/null stderr
        assert_equals "$PWD/store/aaaa-nixos-system-geoffcloud" "$(cut -d' ' -f1 state/system-lag)" "the system the lag state names"
        assert_missing state/imp-lag "imp's lag state"
      '';
    }
    {
      title = "it counts a change to a file the drift check runs from as a system change";
      script = ''
        ${setupTest}
        ${writeGitHub {
          status = "ahead";
          files = [
            { filename = "docs/runbooks/drift-check.md"; }
            { filename = "scripts/check-scheduled-drift.sh"; }
          ];
        }}
        mkdir -p store/aaaa-nixos-system-geoffcloud
        ln -s "$PWD/store/aaaa-nixos-system-geoffcloud" current-system
        echo "${running} $PWD/store/aaaa-nixos-system-geoffcloud" > state/switches
        echo 2.3.0 > impd/version

        run_check

        assert_equals 0 "$status" "the check's exit status"
        assert_files_equal /dev/null stderr
        assert_equals "$PWD/store/aaaa-nixos-system-geoffcloud" "$(cut -d' ' -f1 state/system-lag)" "the system the lag state names"
        assert_missing state/imp-lag "imp's lag state"
      '';
    }
    {
      title = "it reports no system lag when the host runs a newer commit than the green one";
      script = ''
        ${setupTest}
        ${writeGitHub {
          status = "behind";
          files = [ ];
        }}
        mkdir -p store/aaaa-nixos-system-geoffcloud
        ln -s "$PWD/store/aaaa-nixos-system-geoffcloud" current-system
        echo "${running} $PWD/store/aaaa-nixos-system-geoffcloud" > state/switches
        echo 2.3.0 > impd/version

        run_check

        assert_equals 0 "$status" "the check's exit status"
        assert_files_equal /dev/null stderr
        ${maskMetrics}
        assert_files_equal - actual <<'EOF'
        ${metrics "0" "0"}
        EOF
        assert_equals switches "$(ls -A state)" "the state directory"
      '';
    }
    {
      title = "it counts a system that no switch names as lagging, without a comparison";
      script = ''
        ${setupTest}
        ${writeGitHub null}
        mkdir -p store/cccc-nixos-system-geoffcloud
        ln -s "$PWD/store/cccc-nixos-system-geoffcloud" current-system
        echo "${green} $PWD/store/bbbb-nixos-system-geoffcloud" > state/switches
        echo 2.3.0 > impd/version

        run_check

        assert_equals 0 "$status" "the check's exit status"
        assert_files_equal /dev/null stderr
        assert_files_equal - requests <<'EOF'
        ${runsRequest}
        ${configPath}
        EOF
        assert_equals "$PWD/store/cccc-nixos-system-geoffcloud" "$(cut -d' ' -f1 state/system-lag)" "the system the lag state names"
        assert_missing state/imp-lag "imp's lag state"
      '';
    }
    {
      title = "it counts the system as lagging when GitHub no longer holds the commit of its switch";
      script = ''
        ${setupTest}
        ${writeGitHub null}
        mkdir -p store/aaaa-nixos-system-geoffcloud
        ln -s "$PWD/store/aaaa-nixos-system-geoffcloud" current-system
        echo "${running} $PWD/store/aaaa-nixos-system-geoffcloud" > state/switches
        echo 2.3.0 > impd/version

        run_check

        assert_equals 0 "$status" "the check's exit status"
        assert_files_equal /dev/null stdout
        assert_files_equal /dev/null stderr
        assert_files_equal - requests <<'EOF'
        ${runsRequest}
        ${comparePath}
        ${configPath}
        EOF
        assert_equals "$PWD/store/aaaa-nixos-system-geoffcloud" "$(cut -d' ' -f1 state/system-lag)" "the system the lag state names"
        assert_missing state/imp-lag "imp's lag state"
        assert_equals "" "$(ls -A tmp)" "the check's temp directory"
      '';
    }
    {
      title = "it fails and writes nothing when GitHub answers the comparison with another status";
      script = ''
        ${setupTest}
        ${writeGitHub null}
        # http.server redirects a directory's path without its trailing slash, with 301
        mkdir -p "www${comparePath}"
        mkdir -p store/aaaa-nixos-system-geoffcloud
        ln -s "$PWD/store/aaaa-nixos-system-geoffcloud" current-system
        echo "${running} $PWD/store/aaaa-nixos-system-geoffcloud" > state/switches
        echo 2.3.0 > impd/version

        run_check

        assert_equals 1 "$status" "the check's exit status"
        assert_files_equal /dev/null stdout
        assert_equals "host-build-lag: GitHub answered 301 to the comparison of ${running} with ${green}" \
          "$(cat stderr)" "the check's stderr"
        assert_equals "" "$(ls -A out)" "the textfile directory"
        assert_equals switches "$(ls -A state)" "the state directory"
        assert_equals "" "$(ls -A tmp)" "the check's temp directory"
      '';
    }
    {
      title = "it counts imp as lagging when imp-host does not answer";
      script = ''
        ${setupTest}
        ${writeGitHub null}
        mkdir -p store/bbbb-nixos-system-geoffcloud
        ln -s "$PWD/store/bbbb-nixos-system-geoffcloud" current-system
        echo "${green} $PWD/store/bbbb-nixos-system-geoffcloud" > state/switches
        echo 2.3.0 > impd/version
        echo 1 > impd/unreachable

        run_check

        assert_equals 0 "$status" "the check's exit status"
        assert_files_equal /dev/null stdout
        assert_equals "Error response from daemon: No such container: imp-host" "$(cat stderr)" "the check's stderr"
        assert_equals none "$(cut -d' ' -f1 state/imp-lag)" "the imp the lag state names"
        assert_missing state/system-lag "the system's lag state"
      '';
    }
    {
      title = "it fails and leaves the metrics and state as they were when GitHub does not answer";
      script = ''
        ${setupTest}
        mkdir -p store/aaaa-nixos-system-geoffcloud
        ln -s "$PWD/store/aaaa-nixos-system-geoffcloud" current-system
        echo "${running} $PWD/store/aaaa-nixos-system-geoffcloud" > state/switches
        echo 2.2.1 > impd/version
        echo "2.2.1 1000" > state/imp-lag
        echo earlier > out/host_build_lag.prom

        run_check

        assert_equals 22 "$status" "the check's exit status"
        assert_files_equal /dev/null stdout
        assert_equals "curl: (22) The requested URL returned error: 404" "$(cat stderr)" "the check's stderr"
        assert_equals earlier "$(cat out/host_build_lag.prom)" "the metrics"
        assert_equals "2.2.1 1000" "$(cat state/imp-lag)" "imp's lag state"
        assert_equals host_build_lag.prom "$(ls -A out)" "the textfile directory"
      '';
    }
    {
      title = "it fails and writes nothing when main has no green run";
      script = ''
        ${setupTest}
        mkdir -p "www$(dirname ${runsPath})"
        echo '{"workflow_runs":[{"head_sha":"3333333333333333333333333333333333333333","event":"pull_request"}]}' > "www${runsPath}"
        mkdir -p store/aaaa-nixos-system-geoffcloud
        ln -s "$PWD/store/aaaa-nixos-system-geoffcloud" current-system

        run_check

        assert_equals 1 "$status" "the check's exit status"
        assert_files_equal /dev/null stdout
        assert_equals "host-build-lag: no green NixOS checks run on main" "$(cat stderr)" "the check's stderr"
        assert_equals "" "$(ls -A out)" "the textfile directory"
        assert_equals "" "$(ls -A state)" "the state directory"
      '';
    }
  ];
in
pkgs.runCommand "host-build-lag-check"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gnused
      pkgs.gnugrep
      pkgs.jq
      pkgs.python3
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
    source ${pkgs.writeText "host-build-lag-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
