# The scheduled drift check (docs/runbooks/drift-check.md): a daily timer runs a preview-only
# refresh of prod on the host, so the Pulumi passphrase and the state's read token never reach a
# GitHub runner. scripts/run-host-drift-check.sh runs it, with the repo's check and alert scripts
# beside it. The service reads its credentials file through systemd's credentials and starts only
# once that file exists, so a switch before scripts/install-drift-check-credentials.sh installs
# it skips the check instead of failing it.
#
# The check runs from a tree in the store with the layout the scripts expect: scripts/, infra/
# with the project file and a stack file that holds only the state's encryption salt, and
# provider/bin with the Onidel provider that the project file names. A refresh that runs no
# program reads no other stack setting, so a change to the stack's config leaves the tree as it
# is. Pulumi keeps the plugins it downloads under the service's state directory.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.drift-check;
  stateDir = "/var/lib/drift-check";

  stackLines = lib.splitString "\n" (builtins.readFile ../../infra/Pulumi.prod.yaml);
  salt =
    lib.findFirst (lib.hasPrefix "encryptionsalt: ")
      (throw "infra/Pulumi.prod.yaml holds no encryptionsalt line")
      stackLines;

  tree = pkgs.runCommand "drift-check-tree" { } ''
    mkdir -p $out/scripts $out/infra $out/provider/bin
    cp ${../../scripts/run-host-drift-check.sh} $out/scripts/run-host-drift-check.sh
    cp ${../../scripts/check-scheduled-drift.sh} $out/scripts/check-scheduled-drift.sh
    cp ${../../scripts/retry-transient-pulumi.sh} $out/scripts/retry-transient-pulumi.sh
    cp ${../../scripts/alert-scheduled-drift.sh} $out/scripts/alert-scheduled-drift.sh
    cp ${../../infra/Pulumi.yaml} $out/infra/Pulumi.yaml
    printf '%s\n' ${lib.escapeShellArg salt} > $out/infra/Pulumi.prod.yaml
    ln -s ${cfg.onidelProvider}/bin/pulumi-resource-onidel $out/provider/bin/pulumi-resource-onidel
  '';
in
{
  options.services.drift-check = {
    enable = lib.mkEnableOption "the scheduled drift check of the prod stack";

    credentialsFile = lib.mkOption {
      type = lib.types.str;
      example = "/var/lib/tank-cloud/host-secrets/drift-check/credentials";
      description = ''
        The root-only file of KEY=VALUE lines that scripts/install-drift-check-credentials.sh
        writes. systemd copies it into the service's credentials at each start.
      '';
    };

    repo = lib.mkOption {
      type = lib.types.str;
      default = "zgeoff/cloud";
      description = "The GitHub repository whose Deploy prod runs the check waits for.";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 05:41:00 UTC";
      description = "When the timer starts the check, as a systemd calendar event.";
    };

    pulumi = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../packages/pulumi.nix { };
      description = "The Pulumi CLI the check runs.";
    };

    onidelProvider = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../packages/onidel-provider.nix { };
      description = "The Onidel provider that the engine starts for the state's Onidel provider.";
    };

    tree = lib.mkOption {
      type = lib.types.package;
      default = tree;
      readOnly = true;
      description = "The store tree the check runs from, exposed for the flake check.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.drift-check = {
      description = "scheduled drift check of the prod stack";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [
        cfg.pulumi
        pkgs.bash
        pkgs.coreutils
        pkgs.curl
        pkgs.gnugrep
        pkgs.jq
      ];
      environment = {
        HOME = stateDir;
        PULUMI_HOME = "${stateDir}/pulumi";
        PULUMI_SKIP_UPDATE_CHECK = "true";
        RUN_HOST = config.networking.hostName;
        GITHUB_API_URL = "https://api.github.com";
        REPO = cfg.repo;
      };
      unitConfig.ConditionPathExists = cfg.credentialsFile;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash ${tree}/scripts/run-host-drift-check.sh";
        LoadCredential = [ "drift-check:${cfg.credentialsFile}" ];
        # two waits for a Deploy prod run and two checks, each under its own limit, with room for
        # the alert
        TimeoutStartSec = "3h";
        DynamicUser = true;
        StateDirectory = "drift-check";
        StateDirectoryMode = "0700";
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

    systemd.timers.drift-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        # a run that the host missed while it was down starts at the next boot
        Persistent = true;
        AccuracySec = "1min";
      };
    };
  };
}
