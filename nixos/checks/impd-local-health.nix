# Runs the impd local health probe against a stub server in the build sandbox: a ready impd,
# an unready one, and no answer. Run: nix build ./nixos#checks.x86_64-linux.impd-local-health
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
in
pkgs.runCommand "impd-local-health-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.gnugrep
    ];
  }
  ''
    # the module builds a service and a timer
    test -e ${units."impd-local-health.service".unit}
    test -e ${units."impd-local-health.timer".unit}

    mkdir -p www out
    run() { IMPD_HEALTH_URL="$1" TEXTFILE_DIR=out ${probe}/bin/impd-local-health; }
    expect() { grep -qx "$1" out/impd_local_health.prom || { cat out/impd_local_health.prom; echo "missing: $1"; exit 1; }; }

    python3 -m http.server 18080 --bind 127.0.0.1 --directory www >/dev/null 2>&1 &
    server=$!
    for _ in $(seq 50); do python3 -c 'import socket; socket.create_connection(("127.0.0.1", 18080))' 2>/dev/null && break; sleep 0.1; done

    echo '{"status":"ok","ready":true}' > www/health
    run http://127.0.0.1:18080/health
    expect 'impd_local_health_up 1'
    expect 'impd_local_health_status_code 200'

    echo '{"status":"ok","ready":false}' > www/health
    run http://127.0.0.1:18080/health
    expect 'impd_local_health_up 0'
    expect 'impd_local_health_status_code 200'

    run http://127.0.0.1:18080/missing
    expect 'impd_local_health_up 0'
    expect 'impd_local_health_status_code 404'

    kill $server
    run http://127.0.0.1:18080/health
    expect 'impd_local_health_up 0'
    expect 'impd_local_health_status_code 0'

    grep -q '^impd_local_health_last_check_timestamp_seconds [0-9]\+$' out/impd_local_health.prom
    test -z "$(find out -name '.impd_local_health.*')"
    touch $out
  ''
