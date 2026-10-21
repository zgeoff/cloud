# The scheduled drift check (docs/runbooks/drift-check.md): a daily timer runs a preview-only
# refresh of prod on the host, so the Pulumi passphrase and the state's read token never reach a
# GitHub runner. scripts/run-host-drift-check.sh runs it, with the repo's check and alert scripts
# beside it. The service reads its credentials file through systemd's credentials and starts only
# once that file exists, so a switch before scripts/install-drift-check-credentials.sh installs
# it skips the check instead of failing it.
#
# The check holds the prod lock, which Deploy prod also takes, so neither uses the state while the
# other does (scripts/hold-prod-lock.sh). The dynamic user cannot read k3s's admin kubeconfig, so
# root takes the lock before the check and releases it after, with scripts/hold-host-prod-lock.sh
# in ExecStartPre and ExecStopPost. The take writes its status to the service's runtime directory,
# where scripts/run-host-drift-check.sh reads it. Both run with `-`, so a take that fails still
# leaves the check to post the failed alert, and a release that fails leaves the run's status as
# it is: the lease runs out on its own.
#
# The check runs from a tree in the store with the layout the scripts expect: scripts/, infra/
# with the project file and a stack file that holds only the state's encryption salt, and
# provider/bin with the Onidel provider that the project file names. A refresh that runs no
# program reads no other stack setting, so a change to the stack's config leaves the tree as it
# is. Pulumi keeps the plugins it downloads under the service's state directory.
#
# systemd mounts a dynamic user's state directory as an ID-mapped mount with noexec, so a plugin
# there fails to start with `fork/exec …: permission denied`. ExecPaths clears noexec on that mount,
# which systemd makes at /var/lib/private/drift-check inside the service's namespace.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.drift-check;
  stateDir = "/var/lib/drift-check";
  lockStatusFile = "/run/drift-check/lock-status";
  # root's HOME, so kubectl keeps its cache out of the dynamic user's state directory
  holdLock =
    verb:
    "-+${pkgs.coreutils}/bin/env HOME=/root KUBECONFIG=${cfg.kubeconfig} ${pkgs.bash}/bin/bash ${tree}/scripts/hold-host-prod-lock.sh ${verb}";

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
    cp ${../../scripts/hold-prod-lock.sh} $out/scripts/hold-prod-lock.sh
    cp ${../../scripts/hold-host-prod-lock.sh} $out/scripts/hold-host-prod-lock.sh
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

    kubeconfig = lib.mkOption {
      type = lib.types.str;
      default = "/etc/rancher/k3s/k3s.yaml";
      description = "The admin kubeconfig that root takes and releases the prod lock with.";
    };

    kubectl = lib.mkOption {
      type = lib.types.package;
      default = pkgs.kubectl;
      description = "The kubectl that takes and releases the prod lock.";
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
      # k3s's unit reports ready only once its API server answers, so a run that the timer starts
      # at boot waits for the API the prod lock lives in
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
        cfg.kubectl
      ];
      environment = {
        HOME = stateDir;
        PULUMI_HOME = "${stateDir}/pulumi";
        PULUMI_SKIP_UPDATE_CHECK = "true";
        RUN_HOST = config.networking.hostName;
        LOCK_STATUS_FILE = lockStatusFile;
      };
      unitConfig.ConditionPathExists = cfg.credentialsFile;
      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = holdLock "take";
        ExecStart = "${pkgs.bash}/bin/bash ${tree}/scripts/run-host-drift-check.sh";
        ExecStopPost = holdLock "release";
        LoadCredential = [ "drift-check:${cfg.credentialsFile}" ];
        # the wait for the prod lock, up to 6300 s, and the check, up to 2700 s, with room for the
        # alert
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
