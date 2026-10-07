# Checks services.impd-local-health: the units the module generates, and the probe script run
# against a stand-in impd (test-utils/start-stub-impd.py) in the build sandbox. Each case runs on
# its own, in a fresh directory, with its own stand-in on an ephemeral port and its own textfile
# directory, under scripts/test-lib/run-cases.sh, which reports each case and fails the check when
# any case fails.
# Run: bun run test:nixos impd-local-health
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = ../../scripts/test-lib;
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };

  # evaluates a minimal system with the module and one services.impd-local-health config
  buildHealthSystem =
    health:
    lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ../modules/impd-local-health.nix
        {
          # a system needs these to evaluate; no case asserts on them
          system.stateVersion = "26.05";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          services.impd-local-health = health;
        }
      ];
    };

  cases = [
    {
      title = "it runs the probe each minute as impd-health, against loopback only, by default";
      script =
        let
          config = (buildHealthSystem { enable = true; }).config;
          service = config.systemd.services.impd-local-health;
          timer = config.systemd.timers.impd-local-health;
        in
        ''
        # NixOS adds PATH to every service's environment, and tmpfiles rules from every module,
        # so only the impd-health ones are the module's
        jq -S . > actual <<'EOF'
        ${builtins.toJSON {
          service = {
            inherit (service) description wantedBy serviceConfig;
            environment = removeAttrs service.environment [ "PATH" ];
          };
          timer = {
            inherit (timer) wantedBy timerConfig;
          };
          tmpfiles = lib.filter (lib.hasInfix " impd-health ") config.systemd.tmpfiles.rules;
          user = {
            inherit (config.users.users.impd-health) isSystemUser group;
          };
          group = config.users.groups ? impd-health;
        }}
        EOF
        jq -S . > expected <<'EOF'
        ${builtins.toJSON {
          service = {
            description = "impd local health textfile metric";
            wantedBy = [ ];
            environment = {
              IMPD_HEALTH_URL = "http://127.0.0.1:7070/health";
              TEXTFILE_DIR = "/var/lib/node-exporter/textfile";
            };
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${config.services.impd-local-health.package}/bin/impd-local-health";
              User = "impd-health";
              Group = "impd-health";
              NoNewPrivileges = true;
              CapabilityBoundingSet = "";
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              PrivateDevices = true;
              ReadWritePaths = [ "/var/lib/node-exporter/textfile" ];
              RestrictAddressFamilies = [
                "AF_INET"
                "AF_INET6"
              ];
              IPAddressDeny = "any";
              IPAddressAllow = "localhost";
            };
          };
          timer = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "1min";
              OnUnitActiveSec = "1min";
              AccuracySec = "5s";
            };
          };
          tmpfiles = [ "d /var/lib/node-exporter/textfile 0755 impd-health impd-health -" ];
          user = {
            isSystemUser = true;
            group = "impd-health";
          };
          group = true;
        }}
        EOF
        assert_files_equal expected actual
      '';
    }
    {
      title = "it probes the configured url into the configured directory at the configured interval";
      script =
        let
          config = (buildHealthSystem {
            enable = true;
            url = "http://127.0.0.1:9090/ready";
            textfileDir = "/srv/textfile";
            interval = "5min";
          }).config;
          service = config.systemd.services.impd-local-health;
          timer = config.systemd.timers.impd-local-health;
        in
        ''
        # NixOS adds PATH to every service's environment, and tmpfiles rules from every module,
        # so only the impd-health ones are the module's
        jq -S . > actual <<'EOF'
        ${builtins.toJSON {
          service = {
            inherit (service) description wantedBy serviceConfig;
            environment = removeAttrs service.environment [ "PATH" ];
          };
          timer = {
            inherit (timer) wantedBy timerConfig;
          };
          tmpfiles = lib.filter (lib.hasInfix " impd-health ") config.systemd.tmpfiles.rules;
          user = {
            inherit (config.users.users.impd-health) isSystemUser group;
          };
          group = config.users.groups ? impd-health;
        }}
        EOF
        jq -S . > expected <<'EOF'
        ${builtins.toJSON {
          service = {
            description = "impd local health textfile metric";
            wantedBy = [ ];
            environment = {
              IMPD_HEALTH_URL = "http://127.0.0.1:9090/ready";
              TEXTFILE_DIR = "/srv/textfile";
            };
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${config.services.impd-local-health.package}/bin/impd-local-health";
              User = "impd-health";
              Group = "impd-health";
              NoNewPrivileges = true;
              CapabilityBoundingSet = "";
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              PrivateDevices = true;
              ReadWritePaths = [ "/srv/textfile" ];
              RestrictAddressFamilies = [
                "AF_INET"
                "AF_INET6"
              ];
              IPAddressDeny = "any";
              IPAddressAllow = "localhost";
            };
          };
          timer = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "5min";
              OnUnitActiveSec = "5min";
              AccuracySec = "5s";
            };
          };
          tmpfiles = [ "d /srv/textfile 0755 impd-health impd-health -" ];
          user = {
            isSystemUser = true;
            group = "impd-health";
          };
          group = true;
        }}
        EOF
        assert_files_equal expected actual
      '';
    }
    {
      title = "it adds no unit, user or rule when it is off";
      script =
        let
          config = (buildHealthSystem { enable = false; }).config;
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON {
                service = false;
                timer = false;
                user = false;
                tmpfiles = [ ];
              }
            )
          } ${
            lib.escapeShellArg (
              builtins.toJSON {
                service = config.systemd.services ? impd-local-health;
                timer = config.systemd.timers ? impd-local-health;
                user = config.users.users ? impd-health;
                tmpfiles = lib.filter (lib.hasInfix " impd-health ") config.systemd.tmpfiles.rules;
              }
            )
          } "what the module adds"
        '';
    }
    {
      title = "it reports impd up when /health answers 200 with ready true";
      script =
        let
          probe = "${(buildHealthSystem { enable = true; }).config.services.impd-local-health.package}/bin/impd-local-health";
        in
        ''
        mkfifo port.fifo
        exec 3<>port.fifo
        python3 ${./test-utils/start-stub-impd.py} 200 'application/json;charset=utf-8' '{"status":"ok","ready":true}' >&3 &
        stub_pid=$!
        trap 'kill "$stub_pid"' EXIT
        read -r -t 5 -u 3 port
        mkdir out

        before=$(date +%s)
        status=0
        IMPD_HEALTH_URL="http://127.0.0.1:$port/health" TEXTFILE_DIR=out ${probe} > stdout 2> stderr || status=$?
        after=$(date +%s)

        assert_equals 0 "$status" "the probe's exit status"
        assert_files_equal /dev/null stdout
        assert_files_equal /dev/null stderr
        assert_equals impd_local_health.prom "$(ls -A out)" "the textfile directory"
        assert_equals 644 "$(stat -c %a out/impd_local_health.prom)" "the file's mode"
        stamp=$(sed -n 's/^impd_local_health_last_check_timestamp_seconds //p' out/impd_local_health.prom)
        assert_between "$before" "$stamp" "$after" "the timestamp"
        sed "s/^impd_local_health_last_check_timestamp_seconds $stamp\$/impd_local_health_last_check_timestamp_seconds STAMP/" \
          out/impd_local_health.prom > actual
        cat > expected <<'EOF'
        # HELP impd_local_health_up impd answered /health on host loopback with 200 and ready true. Local only, not end-to-end HTTPS.
        # TYPE impd_local_health_up gauge
        impd_local_health_up 1
        # HELP impd_local_health_status_code HTTP status of the last loopback probe, 0 when it got no answer.
        # TYPE impd_local_health_status_code gauge
        impd_local_health_status_code 200
        # HELP impd_local_health_last_check_timestamp_seconds When the last loopback probe ran.
        # TYPE impd_local_health_last_check_timestamp_seconds gauge
        impd_local_health_last_check_timestamp_seconds STAMP
        EOF
        assert_files_equal expected actual
      '';
    }
    {
      title = "it reports impd down when /health answers 200 with ready false";
      script =
        let
          probe = "${(buildHealthSystem { enable = true; }).config.services.impd-local-health.package}/bin/impd-local-health";
        in
        ''
        mkfifo port.fifo
        exec 3<>port.fifo
        python3 ${./test-utils/start-stub-impd.py} 200 'application/json;charset=utf-8' '{"status":"ok","ready":false}' >&3 &
        stub_pid=$!
        trap 'kill "$stub_pid"' EXIT
        read -r -t 5 -u 3 port
        mkdir out

        before=$(date +%s)
        status=0
        IMPD_HEALTH_URL="http://127.0.0.1:$port/health" TEXTFILE_DIR=out ${probe} > stdout 2> stderr || status=$?
        after=$(date +%s)

        assert_equals 0 "$status" "the probe's exit status"
        assert_files_equal /dev/null stdout
        assert_files_equal /dev/null stderr
        assert_equals impd_local_health.prom "$(ls -A out)" "the textfile directory"
        assert_equals 644 "$(stat -c %a out/impd_local_health.prom)" "the file's mode"
        stamp=$(sed -n 's/^impd_local_health_last_check_timestamp_seconds //p' out/impd_local_health.prom)
        assert_between "$before" "$stamp" "$after" "the timestamp"
        sed "s/^impd_local_health_last_check_timestamp_seconds $stamp\$/impd_local_health_last_check_timestamp_seconds STAMP/" \
          out/impd_local_health.prom > actual
        cat > expected <<'EOF'
        # HELP impd_local_health_up impd answered /health on host loopback with 200 and ready true. Local only, not end-to-end HTTPS.
        # TYPE impd_local_health_up gauge
        impd_local_health_up 0
        # HELP impd_local_health_status_code HTTP status of the last loopback probe, 0 when it got no answer.
        # TYPE impd_local_health_status_code gauge
        impd_local_health_status_code 200
        # HELP impd_local_health_last_check_timestamp_seconds When the last loopback probe ran.
        # TYPE impd_local_health_last_check_timestamp_seconds gauge
        impd_local_health_last_check_timestamp_seconds STAMP
        EOF
        assert_files_equal expected actual
      '';
    }
    {
      title = "it reports impd down with the status when no route matches /health";
      script =
        let
          probe = "${(buildHealthSystem { enable = true; }).config.services.impd-local-health.package}/bin/impd-local-health";
        in
        ''
        mkfifo port.fifo
        exec 3<>port.fifo
        python3 ${./test-utils/start-stub-impd.py} 404 'text/plain;charset=utf-8' NOT_FOUND >&3 &
        stub_pid=$!
        trap 'kill "$stub_pid"' EXIT
        read -r -t 5 -u 3 port
        mkdir out

        before=$(date +%s)
        status=0
        IMPD_HEALTH_URL="http://127.0.0.1:$port/health" TEXTFILE_DIR=out ${probe} > stdout 2> stderr || status=$?
        after=$(date +%s)

        assert_equals 0 "$status" "the probe's exit status"
        assert_files_equal /dev/null stdout
        assert_files_equal /dev/null stderr
        assert_equals impd_local_health.prom "$(ls -A out)" "the textfile directory"
        assert_equals 644 "$(stat -c %a out/impd_local_health.prom)" "the file's mode"
        stamp=$(sed -n 's/^impd_local_health_last_check_timestamp_seconds //p' out/impd_local_health.prom)
        assert_between "$before" "$stamp" "$after" "the timestamp"
        sed "s/^impd_local_health_last_check_timestamp_seconds $stamp\$/impd_local_health_last_check_timestamp_seconds STAMP/" \
          out/impd_local_health.prom > actual
        cat > expected <<'EOF'
        # HELP impd_local_health_up impd answered /health on host loopback with 200 and ready true. Local only, not end-to-end HTTPS.
        # TYPE impd_local_health_up gauge
        impd_local_health_up 0
        # HELP impd_local_health_status_code HTTP status of the last loopback probe, 0 when it got no answer.
        # TYPE impd_local_health_status_code gauge
        impd_local_health_status_code 404
        # HELP impd_local_health_last_check_timestamp_seconds When the last loopback probe ran.
        # TYPE impd_local_health_last_check_timestamp_seconds gauge
        impd_local_health_last_check_timestamp_seconds STAMP
        EOF
        assert_files_equal expected actual
      '';
    }
    {
      title = "it reports impd down when /health answers 500 even with ready true";
      script =
        let
          probe = "${(buildHealthSystem { enable = true; }).config.services.impd-local-health.package}/bin/impd-local-health";
        in
        ''
        mkfifo port.fifo
        exec 3<>port.fifo
        python3 ${./test-utils/start-stub-impd.py} 500 'application/json;charset=utf-8' '{"status":"ok","ready":true}' >&3 &
        stub_pid=$!
        trap 'kill "$stub_pid"' EXIT
        read -r -t 5 -u 3 port
        mkdir out

        before=$(date +%s)
        status=0
        IMPD_HEALTH_URL="http://127.0.0.1:$port/health" TEXTFILE_DIR=out ${probe} > stdout 2> stderr || status=$?
        after=$(date +%s)

        assert_equals 0 "$status" "the probe's exit status"
        assert_files_equal /dev/null stdout
        assert_files_equal /dev/null stderr
        assert_equals impd_local_health.prom "$(ls -A out)" "the textfile directory"
        assert_equals 644 "$(stat -c %a out/impd_local_health.prom)" "the file's mode"
        stamp=$(sed -n 's/^impd_local_health_last_check_timestamp_seconds //p' out/impd_local_health.prom)
        assert_between "$before" "$stamp" "$after" "the timestamp"
        sed "s/^impd_local_health_last_check_timestamp_seconds $stamp\$/impd_local_health_last_check_timestamp_seconds STAMP/" \
          out/impd_local_health.prom > actual
        cat > expected <<'EOF'
        # HELP impd_local_health_up impd answered /health on host loopback with 200 and ready true. Local only, not end-to-end HTTPS.
        # TYPE impd_local_health_up gauge
        impd_local_health_up 0
        # HELP impd_local_health_status_code HTTP status of the last loopback probe, 0 when it got no answer.
        # TYPE impd_local_health_status_code gauge
        impd_local_health_status_code 500
        # HELP impd_local_health_last_check_timestamp_seconds When the last loopback probe ran.
        # TYPE impd_local_health_last_check_timestamp_seconds gauge
        impd_local_health_last_check_timestamp_seconds STAMP
        EOF
        assert_files_equal expected actual
      '';
    }
    {
      title = "it reports status 0 when nothing listens";
      script =
        let
          probe = "${(buildHealthSystem { enable = true; }).config.services.impd-local-health.package}/bin/impd-local-health";
        in
        ''
        # a port that answered once and is closed now
        mkfifo port.fifo
        exec 3<>port.fifo
        python3 ${./test-utils/start-stub-impd.py} 200 'application/json;charset=utf-8' '{"status":"ok","ready":true}' >&3 &
        stub_pid=$!
        trap 'kill "$stub_pid" 2>/dev/null || true' EXIT
        read -r -t 5 -u 3 port
        kill "$stub_pid"
        wait "$stub_pid" || true
        mkdir out

        before=$(date +%s)
        status=0
        IMPD_HEALTH_URL="http://127.0.0.1:$port/health" TEXTFILE_DIR=out ${probe} > stdout 2> stderr || status=$?
        after=$(date +%s)

        assert_equals 0 "$status" "the probe's exit status"
        assert_files_equal /dev/null stdout
        assert_files_equal /dev/null stderr
        assert_equals impd_local_health.prom "$(ls -A out)" "the textfile directory"
        assert_equals 644 "$(stat -c %a out/impd_local_health.prom)" "the file's mode"
        stamp=$(sed -n 's/^impd_local_health_last_check_timestamp_seconds //p' out/impd_local_health.prom)
        assert_between "$before" "$stamp" "$after" "the timestamp"
        sed "s/^impd_local_health_last_check_timestamp_seconds $stamp\$/impd_local_health_last_check_timestamp_seconds STAMP/" \
          out/impd_local_health.prom > actual
        cat > expected <<'EOF'
        # HELP impd_local_health_up impd answered /health on host loopback with 200 and ready true. Local only, not end-to-end HTTPS.
        # TYPE impd_local_health_up gauge
        impd_local_health_up 0
        # HELP impd_local_health_status_code HTTP status of the last loopback probe, 0 when it got no answer.
        # TYPE impd_local_health_status_code gauge
        impd_local_health_status_code 0
        # HELP impd_local_health_last_check_timestamp_seconds When the last loopback probe ran.
        # TYPE impd_local_health_last_check_timestamp_seconds gauge
        impd_local_health_last_check_timestamp_seconds STAMP
        EOF
        assert_files_equal expected actual
      '';
    }
    {
      title = "it gives up after a configured 1 s timeout and reports status 0 when impd accepts and never answers";
      script =
        let
          probe = "${(buildHealthSystem { enable = true; }).config.services.impd-local-health.package}/bin/impd-local-health";
        in
        ''
        mkfifo port.fifo
        exec 3<>port.fifo
        python3 ${./test-utils/start-stub-hung-impd.py} >&3 &
        stub_pid=$!
        trap 'kill "$stub_pid"' EXIT
        read -r -t 5 -u 3 port
        mkdir out

        before=$(date +%s)
        status=0
        IMPD_HEALTH_TIMEOUT_SECONDS=1 IMPD_HEALTH_URL="http://127.0.0.1:$port/health" TEXTFILE_DIR=out \
          ${probe} > stdout 2> stderr || status=$?
        after=$(date +%s)

        assert_equals 0 "$status" "the probe's exit status"
        # curl's --max-time 1 ends the probe: at least 1 s, and not much more
        assert_between 1 "$((after - before))" 3 "the probe's run time in seconds"
        assert_files_equal /dev/null stdout
        assert_files_equal /dev/null stderr
        assert_equals impd_local_health.prom "$(ls -A out)" "the textfile directory"
        stamp=$(sed -n 's/^impd_local_health_last_check_timestamp_seconds //p' out/impd_local_health.prom)
        assert_between "$before" "$stamp" "$after" "the timestamp"
        sed "s/^impd_local_health_last_check_timestamp_seconds $stamp\$/impd_local_health_last_check_timestamp_seconds STAMP/" \
          out/impd_local_health.prom > actual
        cat > expected <<'EOF'
        # HELP impd_local_health_up impd answered /health on host loopback with 200 and ready true. Local only, not end-to-end HTTPS.
        # TYPE impd_local_health_up gauge
        impd_local_health_up 0
        # HELP impd_local_health_status_code HTTP status of the last loopback probe, 0 when it got no answer.
        # TYPE impd_local_health_status_code gauge
        impd_local_health_status_code 0
        # HELP impd_local_health_last_check_timestamp_seconds When the last loopback probe ran.
        # TYPE impd_local_health_last_check_timestamp_seconds gauge
        impd_local_health_last_check_timestamp_seconds STAMP
        EOF
        assert_files_equal expected actual
      '';
    }
    {
      title = "it gives up after 5 s when no timeout is configured";
      script =
        let
          probe = "${(buildHealthSystem { enable = true; }).config.services.impd-local-health.package}/bin/impd-local-health";
        in
        ''
        mkfifo port.fifo
        exec 3<>port.fifo
        python3 ${./test-utils/start-stub-hung-impd.py} >&3 &
        stub_pid=$!
        trap 'kill "$stub_pid"' EXIT
        read -r -t 5 -u 3 port
        mkdir out

        before=$(date +%s)
        status=0
        env -u IMPD_HEALTH_TIMEOUT_SECONDS IMPD_HEALTH_URL="http://127.0.0.1:$port/health" TEXTFILE_DIR=out \
          ${probe} > stdout 2> stderr || status=$?
        after=$(date +%s)

        assert_equals 0 "$status" "the probe's exit status"
        # the default --max-time 5 ends the probe: at least 5 s, and not much more
        assert_between 5 "$((after - before))" 7 "the probe's run time in seconds"
        assert_equals "impd_local_health_status_code 0" \
          "$(grep '^impd_local_health_status_code ' out/impd_local_health.prom)" "the status code line"
      '';
    }
    {
      title = "it replaces an existing file with a new one, never writing it in place";
      script =
        let
          probe = "${(buildHealthSystem { enable = true; }).config.services.impd-local-health.package}/bin/impd-local-health";
        in
        ''
        mkfifo port.fifo
        exec 3<>port.fifo
        python3 ${./test-utils/start-stub-impd.py} 200 'application/json;charset=utf-8' '{"status":"ok","ready":true}' >&3 &
        stub_pid=$!
        trap 'kill "$stub_pid"' EXIT
        read -r -t 5 -u 3 port
        mkdir out
        printf 'impd_local_health_up 0\n' > out/impd_local_health.prom
        old_inode=$(stat -c %i out/impd_local_health.prom)
        # a reader holding the old file keeps reading the old content
        exec 4< out/impd_local_health.prom

        status=0
        IMPD_HEALTH_URL="http://127.0.0.1:$port/health" TEXTFILE_DIR=out ${probe} > stdout 2> stderr || status=$?

        assert_equals 0 "$status" "the probe's exit status"
        assert_files_equal /dev/null stdout
        assert_files_equal /dev/null stderr
        assert_equals impd_local_health.prom "$(ls -A out)" "the textfile directory"
        new_inode=$(stat -c %i out/impd_local_health.prom)
        assert_not_equals "$old_inode" "$new_inode" "the file's inode"
        assert_equals 'impd_local_health_up 0' "$(cat <&4)" "what the old reader sees"
        assert_equals 'impd_local_health_up 1' "$(grep '^impd_local_health_up ' out/impd_local_health.prom)" "the new up line"
      '';
    }
    {
      title = "it fails, writing nothing, without a health URL";
      script =
        let
          probe = "${(buildHealthSystem { enable = true; }).config.services.impd-local-health.package}/bin/impd-local-health";
        in
        ''
        mkdir out

        status=0
        env -u IMPD_HEALTH_URL TEXTFILE_DIR=out ${probe} > stdout 2> stderr || status=$?

        assert_equals 1 "$status" "the probe's exit status"
        assert_files_equal /dev/null stdout
        # the line number moves with any edit to the script
        assert_equals "${probe}: line N: IMPD_HEALTH_URL: unbound variable" \
          "$(sed 's/: line [0-9]*: /: line N: /' stderr)" "the probe's stderr"
        assert_equals "" "$(ls -A out)" "the textfile directory"
      '';
    }
    {
      title = "it fails, writing nothing, without a textfile directory";
      script =
        let
          probe = "${(buildHealthSystem { enable = true; }).config.services.impd-local-health.package}/bin/impd-local-health";
        in
        ''
        mkfifo port.fifo
        exec 3<>port.fifo
        python3 ${./test-utils/start-stub-impd.py} 200 'application/json;charset=utf-8' '{"status":"ok","ready":true}' >&3 &
        stub_pid=$!
        trap 'kill "$stub_pid"' EXIT
        read -r -t 5 -u 3 port
        mkdir out

        status=0
        env -u TEXTFILE_DIR IMPD_HEALTH_URL="http://127.0.0.1:$port/health" ${probe} > stdout 2> stderr || status=$?

        assert_equals 1 "$status" "the probe's exit status"
        assert_files_equal /dev/null stdout
        # the line number moves with any edit to the script
        assert_equals "${probe}: line N: TEXTFILE_DIR: unbound variable" \
          "$(sed 's/: line [0-9]*: /: line N: /' stderr)" "the probe's stderr"
        assert_equals "" "$(ls -A out)" "the textfile directory"
      '';
    }
    {
      title = "it fails, leaving no temp file, when the textfile directory does not exist";
      script =
        let
          probe = "${(buildHealthSystem { enable = true; }).config.services.impd-local-health.package}/bin/impd-local-health";
        in
        ''
        mkfifo port.fifo
        exec 3<>port.fifo
        python3 ${./test-utils/start-stub-impd.py} 200 'application/json;charset=utf-8' '{"status":"ok","ready":true}' >&3 &
        stub_pid=$!
        trap 'kill "$stub_pid"' EXIT
        read -r -t 5 -u 3 port
        mkdir tmp

        status=0
        TMPDIR=$PWD/tmp IMPD_HEALTH_URL="http://127.0.0.1:$port/health" TEXTFILE_DIR=missing ${probe} > stdout 2> stderr || status=$?

        assert_equals 1 "$status" "the probe's exit status"
        assert_files_equal /dev/null stdout
        assert_equals "mktemp: failed to create file via template 'missing/.impd_local_health.XXXXXX': No such file or directory" \
          "$(cat stderr)" "the probe's stderr"
        assert_equals "" "$(ls -A tmp)" "the probe's temp directory"
        assert_missing missing "the textfile directory"
      '';
    }
    {
      title = "it fails, leaving the directory empty, when the textfile directory is not writable";
      script =
        let
          probe = "${(buildHealthSystem { enable = true; }).config.services.impd-local-health.package}/bin/impd-local-health";
        in
        ''
        mkfifo port.fifo
        exec 3<>port.fifo
        python3 ${./test-utils/start-stub-impd.py} 200 'application/json;charset=utf-8' '{"status":"ok","ready":true}' >&3 &
        stub_pid=$!
        trap 'kill "$stub_pid"' EXIT
        read -r -t 5 -u 3 port
        mkdir tmp out
        # the build user is not root, so 0555 holds
        chmod 0555 out

        status=0
        TMPDIR=$PWD/tmp IMPD_HEALTH_URL="http://127.0.0.1:$port/health" TEXTFILE_DIR=out ${probe} > stdout 2> stderr || status=$?

        assert_equals 1 "$status" "the probe's exit status"
        assert_files_equal /dev/null stdout
        assert_equals "mktemp: failed to create file via template 'out/.impd_local_health.XXXXXX': Permission denied" \
          "$(cat stderr)" "the probe's stderr"
        assert_equals "" "$(ls -A out)" "the textfile directory"
        assert_equals "" "$(ls -A tmp)" "the probe's temp directory"
      '';
    }
  ];
in
pkgs.runCommand "impd-local-health-check"
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
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${testLib}/assert-not-equals.sh
    source ${testLib}/assert-files-equal.sh
    source ${testLib}/assert-between.sh
    source ${testLib}/assert-missing.sh
    source ${pkgs.writeText "impd-local-health-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
