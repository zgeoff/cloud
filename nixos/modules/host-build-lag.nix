# Host build lag: a timer compares the system and imp that the host runs with the latest green main
# build on GitHub, and writes how long each has lagged behind it as node-exporter textfile metrics
# (host-build-lag.sh). The HostBehindLatestBuild alert fires on them, because a merged change to
# the host waits for a person to switch it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.host-build-lag;
  topology = import ../topology.nix;

  check = pkgs.writeShellApplication {
    name = "host-build-lag";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gnused
      pkgs.jq
    ];
    text = builtins.readFile ./host-build-lag.sh;
  };
in
{
  options.services.host-build-lag = {
    enable = lib.mkEnableOption "the host build lag textfile metric";

    repo = lib.mkOption {
      type = lib.types.str;
      default = "zgeoff/cloud";
      description = "The GitHub repository whose green main build the host should run.";
    };

    textfileDir = lib.mkOption {
      type = lib.types.str;
      default = topology.nodeExporter.textfileDir;
      description = "The directory node-exporter's textfile collector reads.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "1h";
      description = "How often the timer checks.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = check;
      readOnly = true;
      description = "The check script, exposed for the flake check.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.host-build-lag = {
      description = "host build lag textfile metric";
      environment = {
        REPO = cfg.repo;
        TEXTFILE_DIR = cfg.textfileDir;
        # scripts/switch-geoffcloud.sh appends each switch's commit to switches in this directory
        STATE_DIR = "/var/lib/host-build-lag";
        CURRENT_SYSTEM = "/run/current-system";
        GITHUB_API_URL = "https://api.github.com";
        GITHUB_RAW_URL = "https://raw.githubusercontent.com";
        DOCKER = lib.getExe config.virtualisation.docker.package;
      };
      # root, since docker's socket is root's
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe check;
        StateDirectory = "host-build-lag";
        NoNewPrivileges = true;
        ProtectSystem = "full";
        PrivateTmp = true;
      };
    };

    systemd.timers.host-build-lag = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "1min";
      };
    };
  };
}
