# atc's daemon on a cloud host, for the atc gateway to dial (docs/plans/atc-gateway.md).
# A template: atc has not released the daemon's tailnet listener, so the command and
# its flags are options. Off by default, and not imported by any host yet; enabling it
# opens a listener and needs approval (docs/runbooks/atc-gateway-operator-checklist.md).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.atc-daemon;
in
{
  options.services.atc-daemon = {
    enable = lib.mkEnableOption "atc's daemon, reached by the atc gateway";

    package = lib.mkOption {
      type = lib.types.package;
      description = "A package whose bin/atc is a pinned atc release (deploy/atc-gateway/versions.env).";
    };

    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "daemon" ];
      description = "atc's arguments. atc's gateway work fixes the listener flags (provisional: host and port 8415).";
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      example = "/var/lib/atc-daemon/secrets/gateway-token";
      description = ''
        A root-only file holding the bearer token the gateway presents. It is passed in
        with systemd LoadCredential, so the service user never reads the file itself.
      '';
    };

    impTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "impd's named token for the daemon (scope manage, imps harness-*), also via LoadCredential.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.atc = {
      isSystemUser = true;
      group = "atc";
      home = "/var/lib/atc-daemon";
    };
    users.groups.atc = { };

    systemd.services.atc-daemon = {
      description = "atc daemon";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "tailscaled.service"
      ];
      wants = [ "network-online.target" ];
      environment = {
        HOME = "/var/lib/atc-daemon";
        XDG_RUNTIME_DIR = "/run/atc-daemon";
      };
      serviceConfig = {
        ExecStart = lib.escapeShellArgs ([ "${cfg.package}/bin/atc" ] ++ cfg.args);
        User = "atc";
        Group = "atc";
        StateDirectory = "atc-daemon";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "atc-daemon";
        LoadCredential = [
          "gateway-token:${cfg.tokenFile}"
        ]
        ++ lib.optional (cfg.impTokenFile != null) "imp-token:${cfg.impTokenFile}";
        Restart = "on-failure";
        RestartSec = 5;
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
  };
}
