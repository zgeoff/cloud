# Evaluates services.atc-daemon with a stand-in binary, apart from any host's config, and checks
# the unit and config.json it generates and the module's two assertions. Each case runs on its
# own and reports ok or not ok; the check fails when any case fails.
# Run: nix build ./nixos#checks.x86_64-linux.atc-daemon
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;

  # the stand-in package: bin/atc only has to exist, nothing runs it
  atc = pkgs.writeShellScriptBin "atc" "exec sleep infinity";

  # a minimal system with the module and one services.atc-daemon config
  evalDaemon =
    daemon:
    lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ../modules/atc-daemon.nix
        {
          system.stateVersion = "26.05";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          services.atc-daemon = daemon;
        }
      ];
    };

  # the messages of every assertion that fails, in the order the system lists them
  failedAssertions =
    system: map (a: a.message) (lib.filter (a: !a.assertion) system.config.assertions);

  daemonUnit = system: "${system.config.systemd.units."atc-daemon.service".unit}/atc-daemon.service";
  daemonConfig = system: builtins.head system.config.systemd.services.atc-daemon.restartTriggers;

  full = evalDaemon {
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
  };

  withoutImpToken = evalDaemon {
    enable = true;
    package = atc;
    listen = "100.64.0.1:8415";
    tokenFile = "/run/fixture/gateway-token";
    impTokenFile = null;
    targets.geoffcloud = {
      provider = "imp";
      url = "http://127.0.0.1:7070";
      tokenFile = "/run/credentials/atc-daemon.service/imp-token";
      impPrefix = "harness-";
    };
    defaultTarget = "geoffcloud";
    principals.fixture-client.targets = [ "geoffcloud" ];
  };

  withoutDefaultTarget = evalDaemon {
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
    defaultTarget = null;
    principals.fixture-client.targets = [ "geoffcloud" ];
  };

  unknownGrant = evalDaemon {
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
    principals.fixture-client.targets = [
      "geoffcloud"
      "elsewhere"
    ];
  };

  unknownDefaultTarget = evalDaemon {
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
    defaultTarget = "elsewhere";
    principals.fixture-client.targets = [ "geoffcloud" ];
  };
in
pkgs.runCommand "atc-daemon-check"
  {
    nativeBuildInputs = [
      pkgs.diffutils
      pkgs.gnugrep
      pkgs.jq
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

    case_unit_lines() {
      unit=${daemonUnit full}
      grep -E '^(ExecStart|LoadCredential|BindReadOnlyPaths)=' "$unit" > actual
      printf '%s\n' \
        'BindReadOnlyPaths=${pkgs.glibc}/lib/ld-linux-x86-64.so.2:/lib64/ld-linux-x86-64.so.2' \
        'ExecStart=${atc}/bin/atc daemon --listen 100.64.0.1:8415 --token-file %d/gateway-token' \
        'LoadCredential=gateway-token:/run/fixture/gateway-token' \
        'LoadCredential=imp-token:/run/fixture/imp-token' > expected
      sort actual | diff -u expected -
    }

    case_config_json() {
      jq -S . ${daemonConfig full} > actual
      jq -S . > expected <<'EOF'
    {
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
      diff -u expected actual
    }

    case_no_imp_token() {
      grep -E '^LoadCredential=' ${daemonUnit withoutImpToken} > actual
      printf '%s\n' 'LoadCredential=gateway-token:/run/fixture/gateway-token' > expected
      diff -u expected actual
    }

    case_no_default_target() {
      jq -S . ${daemonConfig withoutDefaultTarget} > actual
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
      diff -u expected actual
    }

    case_valid_config_passes_assertions() {
      jq . > actual <<'EOF'
    ${builtins.toJSON (failedAssertions full)}
    EOF
      echo '[]' | jq . > expected
      diff -u expected actual
    }

    case_unknown_grant() {
      jq . > actual <<'EOF'
    ${builtins.toJSON (failedAssertions unknownGrant)}
    EOF
      jq . > expected <<'EOF'
    ["services.atc-daemon.principals grants targets that services.atc-daemon.targets does not define: fixture-client -> elsewhere"]
    EOF
      diff -u expected actual
    }

    case_unknown_default_target() {
      jq . > actual <<'EOF'
    ${builtins.toJSON (failedAssertions unknownDefaultTarget)}
    EOF
      jq . > expected <<'EOF'
    ["services.atc-daemon.defaultTarget must name one of services.atc-daemon.targets"]
    EOF
      diff -u expected actual
    }

    run_case "it runs atc daemon with the gateway token credential and the glibc loader" unit case_unit_lines
    run_case "it writes the targets, principals and default target to config.json" config case_config_json
    run_case "it loads only the gateway token when impTokenFile is null" no-imp-token case_no_imp_token
    run_case "it leaves defaultTarget out of config.json when it is null" no-default case_no_default_target
    run_case "it fails no assertion for a valid config" valid case_valid_config_passes_assertions
    run_case "it rejects a principal granted a target that is not defined" grant case_unknown_grant
    run_case "it rejects a default target that is not defined" default case_unknown_default_target

    if [ "$failed" != 0 ]; then
      echo "$failed case(s) failed"
      exit 1
    fi
    touch $out
  ''
