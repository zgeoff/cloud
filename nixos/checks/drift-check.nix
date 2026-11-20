# Checks services.drift-check: the units the module generates, the store tree the check runs
# from, and the Pulumi CLI it ships, run in the build sandbox. scripts/run-host-drift-check.bats
# tests the scripts themselves, and checks/drift-check-vm.nix runs the unit on a booted VM. Each
# case runs on its own, in a fresh directory, as a bats test.
# Run: bun run test:nixos drift-check
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };

  config =
    (buildModuleSystem ../modules/drift-check.nix {
      networking.hostName = "drift-host";
      services.drift-check = {
        enable = true;
        credentialsFile = "/var/lib/secrets/drift-check/credentials";
      };
    }).config;
  cfg = config.services.drift-check;

  cases = [
    {
      title = "it checks every day as a dynamic user with its credentials file and the tree, once that file exists, holding the prod lock as root around the check";
      script =
        let
          service = config.systemd.services.drift-check;
          timer = config.systemd.timers.drift-check;
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            service = {
              description = "scheduled drift check of the prod stack";
              wantedBy = [ ];
              after = [
                "network-online.target"
                "k3s.service"
              ];
              wants = [ "network-online.target" ];
              path = [
                cfg.pulumi
                pkgs.bash
                pkgs.coreutils
                pkgs.curl
                pkgs.gnugrep
                pkgs.jq
                pkgs.kubectl
                # the path NixOS appends to every service's
                pkgs.coreutils
                pkgs.findutils
                pkgs.gnugrep
                pkgs.gnused
                config.systemd.package
              ];
              environment = {
                HOME = "/var/lib/drift-check";
                PULUMI_HOME = "/var/lib/drift-check/pulumi";
                PULUMI_SKIP_UPDATE_CHECK = "true";
                RUN_HOST = "drift-host";
                LOCK_STATUS_FILE = "/run/drift-check/lock-status";
              };
              # NixOS renders the description, after and wants into unitConfig too
              unitConfig = {
                ConditionPathExists = "/var/lib/secrets/drift-check/credentials";
                Description = "scheduled drift check of the prod stack";
                After = "network-online.target k3s.service";
                Wants = "network-online.target";
              };
              serviceConfig = {
                Type = "oneshot";
                ExecStartPre = "-+${pkgs.coreutils}/bin/env HOME=/root KUBECONFIG=/etc/rancher/k3s/k3s.yaml ${pkgs.bash}/bin/bash ${cfg.tree}/scripts/hold-host-prod-lock.sh take";
                ExecStart = "${pkgs.bash}/bin/bash ${cfg.tree}/scripts/run-host-drift-check.sh";
                ExecStopPost = "-+${pkgs.coreutils}/bin/env HOME=/root KUBECONFIG=/etc/rancher/k3s/k3s.yaml ${pkgs.bash}/bin/bash ${cfg.tree}/scripts/hold-host-prod-lock.sh release";
                LoadCredential = [ "drift-check:/var/lib/secrets/drift-check/credentials" ];
                TimeoutStartSec = "3h";
                DynamicUser = true;
                StateDirectory = "drift-check";
                StateDirectoryMode = "0700";
                RuntimeDirectory = "drift-check";
                ExecPaths = [ "/var/lib/private/drift-check" ];
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
            };
            timer = {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = "*-*-* 05:41:00 UTC";
                Persistent = true;
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
                path
                unitConfig
                serviceConfig
                ;
              environment = removeAttrs service.environment [ "PATH" ];
            };
            timer = {
              inherit (timer) wantedBy timerConfig;
            };
          }}
          EOF

          diff -u expected actual
        '';
    }
    {
      title = "it adds no unit when it is off";
      script =
        let
          off = (buildModuleSystem ../modules/drift-check.nix { }).config;
        in
        ''
          # a drift-check service
          assert_equal ${lib.boolToString (off.systemd.services ? drift-check)} false
          # a drift-check timer
          assert_equal ${lib.boolToString (off.systemd.timers ? drift-check)} false
        '';
    }
    {
      title = "it runs from a tree of the repo scripts, the project file, a stack file of only the salt and the provider";
      script = ''
        (cd ${cfg.tree} && find . | LC_ALL=C sort) > listing
        diff -u ${pkgs.writeText "listing" ''
          .
          ./infra
          ./infra/Pulumi.prod.yaml
          ./infra/Pulumi.yaml
          ./provider
          ./provider/bin
          ./provider/bin/pulumi-resource-onidel
          ./scripts
          ./scripts/alert-scheduled-drift.sh
          ./scripts/check-scheduled-drift.sh
          ./scripts/hold-host-prod-lock.sh
          ./scripts/hold-prod-lock.sh
          ./scripts/retry-transient-pulumi.sh
          ./scripts/run-host-drift-check.sh
        ''} listing
        diff -u ${../../scripts/alert-scheduled-drift.sh} ${cfg.tree}/scripts/alert-scheduled-drift.sh
        diff -u ${../../scripts/check-scheduled-drift.sh} ${cfg.tree}/scripts/check-scheduled-drift.sh
        diff -u ${../../scripts/hold-host-prod-lock.sh} ${cfg.tree}/scripts/hold-host-prod-lock.sh
        diff -u ${../../scripts/hold-prod-lock.sh} ${cfg.tree}/scripts/hold-prod-lock.sh
        diff -u ${../../scripts/retry-transient-pulumi.sh} ${cfg.tree}/scripts/retry-transient-pulumi.sh
        diff -u ${../../scripts/run-host-drift-check.sh} ${cfg.tree}/scripts/run-host-drift-check.sh
        diff -u ${../../infra/Pulumi.yaml} ${cfg.tree}/infra/Pulumi.yaml
        grep '^encryptionsalt: ' ${../../infra/Pulumi.prod.yaml} > salt
        diff -u salt ${cfg.tree}/infra/Pulumi.prod.yaml
        assert_equal "$(readlink ${cfg.tree}/provider/bin/pulumi-resource-onidel)" ${cfg.onidelProvider}/bin/pulumi-resource-onidel
        test -x ${cfg.onidelProvider}/bin/pulumi-resource-onidel
      '';
    }
    {
      title = "it ships a Pulumi CLI that runs in the sandbox, with the Bun language host and the Node.js host it runs beside it";
      script = ''
        mkdir home
        HOME="$PWD/home" PULUMI_HOME="$PWD/home/.pulumi" PULUMI_SKIP_UPDATE_CHECK=true \
          ${cfg.pulumi}/bin/pulumi version > version
        assert_equal "$(cat version)" v3.268.0
        test -x ${cfg.pulumi}/bin/pulumi-language-bun
        test -x ${cfg.pulumi}/bin/pulumi-language-nodejs
      '';
    }
  ];
in
pkgs.runCommand "drift-check-check"
  {
    nativeBuildInputs = [
      (pkgs.bats.withLibraries (p: [
        p.bats-support
        p.bats-assert
      ]))
      pkgs.coreutils
      pkgs.diffutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.jq
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    # fixed, so the modes the cases assert do not depend on the builder's umask
    umask 022
    bats --timing --print-output-on-failure ${pkgs.writeText "drift-check.bats" (renderCases cases)}
    touch $out
  ''
