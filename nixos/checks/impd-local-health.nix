# Runs the impd local health probe against a stub impd in the build sandbox, one named case at a
# time, each with its own stub on an ephemeral port and its own textfile directory, and checks the
# service and timer the module generates. Each case reports ok or not ok; the check fails when any
# case fails. Run: nix build ./nixos#checks.x86_64-linux.impd-local-health
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  system = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      ../modules/impd-local-health.nix
      {
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        services.impd-local-health.enable = true;
      }
    ];
  };
  probe = system.config.services.impd-local-health.package;
  units = system.config.systemd.units;

  # A stand-in impd: answers every GET with one status and body, as JSON, the way impd's Elysia
  # app answers /health with { status: 'ok', ready } (imp, packages/daemon/src/build-app.ts at the
  # pinned input). It listens on an ephemeral port and writes that port to a file once it accepts.
  stubImpd = pkgs.writeText "stub-impd.py" ''
    import http.server
    import os
    import sys

    status, body, port_file = int(sys.argv[1]), sys.argv[2].encode(), sys.argv[3]


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass


    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    with open(port_file + ".tmp", "w") as f:
        f.write(str(server.server_address[1]))
    os.rename(port_file + ".tmp", port_file)
    server.serve_forever()
  '';
in
pkgs.runCommand "impd-local-health-check"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gnugrep
      pkgs.python3
    ];
  }
  ''
    failed=0
    # runs one case in its own directory and subshell with set -e, so a failing case reports
    # and the rest still run
    run_case() {
      mkdir "$2"
      set +e
      (
        cd "$2"
        set -euo pipefail
        "$3"
      )
      status=$?
      set -e
      if [ "$status" = 0 ]; then
        echo "ok - $1"
      else
        echo "not ok - $1"
        failed=$((failed + 1))
      fi
    }

    # starts the stub with a status and body; sets stub_pid and stub_port, or fails after 5 s
    start_stub() {
      python3 ${stubImpd} "$1" "$2" port &
      stub_pid=$!
      for _ in $(seq 50); do
        [ -s port ] && break
        sleep 0.1
      done
      [ -s port ] || { echo "the stub wrote no port within 5 s"; return 1; }
      stub_port=$(cat port)
    }

    stop_stub() {
      kill "$stub_pid"
      wait "$stub_pid" || true
    }

    # runs the probe once into ./out; sets probe_status, before and after
    run_probe() {
      mkdir -p out
      before=$(date +%s)
      set +e
      IMPD_HEALTH_URL="$1" TEXTFILE_DIR=out ${probe}/bin/impd-local-health
      probe_status=$?
      set -e
      after=$(date +%s)
    }

    # the probe exited 0, wrote one 0644 file and left no temp file, and its timestamp line falls
    # within the run; prints the file without that line, for the case to compare whole
    check_probe_output() {
      [ "$probe_status" = 0 ] || { echo "the probe exited $probe_status"; return 1; }
      [ "$(ls -A out)" = impd_local_health.prom ] || { echo "out holds: $(ls -A out)"; return 1; }
      [ "$(stat -c %a out/impd_local_health.prom)" = 644 ] || { echo "mode $(stat -c %a out/impd_local_health.prom)"; return 1; }
      stamps=$(grep -c '^impd_local_health_last_check_timestamp_seconds ' out/impd_local_health.prom || true)
      [ "$stamps" = 1 ] || { echo "$stamps timestamp lines"; return 1; }
      stamp=$(sed -n 's/^impd_local_health_last_check_timestamp_seconds \([0-9]\{1,\}\)$/\1/p' out/impd_local_health.prom)
      [ -n "$stamp" ] && [ "$stamp" -ge "$before" ] && [ "$stamp" -le "$after" ] ||
        { echo "timestamp '$stamp' is outside $before..$after"; return 1; }
      grep -v '^impd_local_health_last_check_timestamp_seconds ' out/impd_local_health.prom > actual
    }

    case_ready() {
      start_stub 200 '{"status":"ok","ready":true}'
      run_probe "http://127.0.0.1:$stub_port/health"
      stop_stub
      check_probe_output
      cat > expected <<'EOF'
    # HELP impd_local_health_up impd answered /health on host loopback with 200 and ready true. Local only, not end-to-end HTTPS.
    # TYPE impd_local_health_up gauge
    impd_local_health_up 1
    # HELP impd_local_health_status_code HTTP status of the last loopback probe, 0 when it got no answer.
    # TYPE impd_local_health_status_code gauge
    impd_local_health_status_code 200
    # HELP impd_local_health_last_check_timestamp_seconds When the last loopback probe ran.
    # TYPE impd_local_health_last_check_timestamp_seconds gauge
    EOF
      diff -u expected actual
    }

    case_unready() {
      start_stub 200 '{"status":"ok","ready":false}'
      run_probe "http://127.0.0.1:$stub_port/health"
      stop_stub
      check_probe_output
      cat > expected <<'EOF'
    # HELP impd_local_health_up impd answered /health on host loopback with 200 and ready true. Local only, not end-to-end HTTPS.
    # TYPE impd_local_health_up gauge
    impd_local_health_up 0
    # HELP impd_local_health_status_code HTTP status of the last loopback probe, 0 when it got no answer.
    # TYPE impd_local_health_status_code gauge
    impd_local_health_status_code 200
    # HELP impd_local_health_last_check_timestamp_seconds When the last loopback probe ran.
    # TYPE impd_local_health_last_check_timestamp_seconds gauge
    EOF
      diff -u expected actual
    }

    case_not_found() {
      start_stub 404 'NOT_FOUND'
      run_probe "http://127.0.0.1:$stub_port/health"
      stop_stub
      check_probe_output
      cat > expected <<'EOF'
    # HELP impd_local_health_up impd answered /health on host loopback with 200 and ready true. Local only, not end-to-end HTTPS.
    # TYPE impd_local_health_up gauge
    impd_local_health_up 0
    # HELP impd_local_health_status_code HTTP status of the last loopback probe, 0 when it got no answer.
    # TYPE impd_local_health_status_code gauge
    impd_local_health_status_code 404
    # HELP impd_local_health_last_check_timestamp_seconds When the last loopback probe ran.
    # TYPE impd_local_health_last_check_timestamp_seconds gauge
    EOF
      diff -u expected actual
    }

    case_error_with_ready_body() {
      start_stub 500 '{"status":"ok","ready":true}'
      run_probe "http://127.0.0.1:$stub_port/health"
      stop_stub
      check_probe_output
      cat > expected <<'EOF'
    # HELP impd_local_health_up impd answered /health on host loopback with 200 and ready true. Local only, not end-to-end HTTPS.
    # TYPE impd_local_health_up gauge
    impd_local_health_up 0
    # HELP impd_local_health_status_code HTTP status of the last loopback probe, 0 when it got no answer.
    # TYPE impd_local_health_status_code gauge
    impd_local_health_status_code 500
    # HELP impd_local_health_last_check_timestamp_seconds When the last loopback probe ran.
    # TYPE impd_local_health_last_check_timestamp_seconds gauge
    EOF
      diff -u expected actual
    }

    case_no_answer() {
      # a port that answered once and is closed now, so nothing listens on it
      start_stub 200 '{"status":"ok","ready":true}'
      stop_stub
      run_probe "http://127.0.0.1:$stub_port/health"
      check_probe_output
      cat > expected <<'EOF'
    # HELP impd_local_health_up impd answered /health on host loopback with 200 and ready true. Local only, not end-to-end HTTPS.
    # TYPE impd_local_health_up gauge
    impd_local_health_up 0
    # HELP impd_local_health_status_code HTTP status of the last loopback probe, 0 when it got no answer.
    # TYPE impd_local_health_status_code gauge
    impd_local_health_status_code 0
    # HELP impd_local_health_last_check_timestamp_seconds When the last loopback probe ran.
    # TYPE impd_local_health_last_check_timestamp_seconds gauge
    EOF
      diff -u expected actual
    }

    case_service_unit() {
      grep -E '^(Environment="(IMPD_HEALTH_URL|TEXTFILE_DIR)=|ExecStart=|Type=|User=|Group=|ReadWritePaths=|IPAddressDeny=|IPAddressAllow=)' \
        ${units."impd-local-health.service".unit}/impd-local-health.service | sort > actual
      printf '%s\n' \
        'Environment="IMPD_HEALTH_URL=http://127.0.0.1:7070/health"' \
        'Environment="TEXTFILE_DIR=/var/lib/node-exporter/textfile"' \
        'ExecStart=${probe}/bin/impd-local-health' \
        'Group=impd-health' \
        'IPAddressAllow=localhost' \
        'IPAddressDeny=any' \
        'ReadWritePaths=/var/lib/node-exporter/textfile' \
        'Type=oneshot' \
        'User=impd-health' | sort > expected
      diff -u expected actual
    }

    case_timer_unit() {
      grep -E '^(OnBootSec|OnUnitActiveSec|AccuracySec)=' \
        ${units."impd-local-health.timer".unit}/impd-local-health.timer | sort > actual
      printf '%s\n' 'AccuracySec=5s' 'OnBootSec=1min' 'OnUnitActiveSec=1min' > expected
      diff -u expected actual
    }

    run_case "it reports impd up when /health answers 200 with ready true" ready case_ready
    run_case "it reports impd down when /health answers 200 with ready false" unready case_unready
    run_case "it reports impd down with the status when /health answers 404" not-found case_not_found
    run_case "it reports impd down when /health answers 500 even with ready true" error case_error_with_ready_body
    run_case "it reports status 0 when nothing answers" no-answer case_no_answer
    run_case "it runs the probe as impd-health against loopback only" service case_service_unit
    run_case "it runs the timer every minute" timer case_timer_unit

    if [ "$failed" != 0 ]; then
      echo "$failed case(s) failed"
      exit 1
    fi
    touch $out
  ''
