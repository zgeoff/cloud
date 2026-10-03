# impd local health (#29): a timer reads impd's /health on host loopback and writes the result
# as node-exporter textfile metrics. It covers impd answering on the host only, not the HTTPS
# path through the tailnet: tag:cloud has no grant to tag:imp, by imp's isolation design.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.impd-local-health;

  probe = pkgs.writeShellApplication {
    name = "impd-local-health";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gnugrep
    ];
    text = builtins.readFile ./impd-local-health.sh;
  };
in
{
  options.services.impd-local-health = {
    enable = lib.mkEnableOption "the impd local health textfile metric";

    url = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:7070/health";
      description = "impd's health endpoint on host loopback.";
    };

    textfileDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter/textfile";
      description = "The directory node-exporter's textfile collector reads.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "1min";
      description = "How often the timer probes.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = probe;
      readOnly = true;
      description = "The probe script, exposed for the flake check.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.impd-health = {
      isSystemUser = true;
      group = "impd-health";
    };
    users.groups.impd-health = { };

    # node-exporter (uid 65534 in its pod) reads this directory through /host/root
    systemd.tmpfiles.rules = [ "d ${cfg.textfileDir} 0755 impd-health impd-health -" ];

    systemd.services.impd-local-health = {
      description = "impd local health textfile metric";
      environment = {
        IMPD_HEALTH_URL = cfg.url;
        TEXTFILE_DIR = cfg.textfileDir;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe probe;
        User = "impd-health";
        Group = "impd-health";
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ReadWritePaths = [ cfg.textfileDir ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
      };
    };

    systemd.timers.impd-local-health = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.interval;
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "5s";
      };
    };
  };
}
