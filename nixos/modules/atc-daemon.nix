# atc's daemon on a cloud host, for the atc gateway to dial (docs/plans/atc-gateway.md).
# It runs `atc daemon --listen <addr> --token-file <credential>`: a gateway presents the
# token, and `principals` decides which execution targets each client reaches. Off by
# default, and not imported by any host yet; enabling it opens a listener and needs
# approval (docs/runbooks/atc-gateway-operator-checklist.md).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.atc-daemon;
  json = pkgs.formats.json { };
  home = "/var/lib/atc-daemon";

  # atc reads $HOME/.config/atc/config.json; this daemon sets only its targets and
  # principals there
  configFile = json.generate "atc-daemon-config.json" (
    {
      inherit (cfg) targets;
      principals = lib.mapAttrs (_: principal: { inherit (principal) targets; }) cfg.principals;
    }
    // lib.optionalAttrs (cfg.defaultTarget != null) { inherit (cfg) defaultTarget; }
  );

  # links the store's config where atc looks; atc writes a default config only when
  # none exists, so it leaves the link alone
  linkConfig = pkgs.writeShellScript "atc-daemon-link-config" ''
    set -eu
    mkdir -p ${home}/.config/atc
    ln -sfn ${configFile} ${home}/.config/atc/config.json
  '';

  # each grant that names a target the config does not define
  unknownGrants = lib.concatLists (
    lib.mapAttrsToList (
      id: principal:
      map (target: "${id} -> ${target}") (lib.filter (target: !(cfg.targets ? ${target})) principal.targets)
    ) cfg.principals
  );
in
{
  options.services.atc-daemon = {
    enable = lib.mkEnableOption "atc's daemon, reached by the atc gateway";

    package = lib.mkOption {
      type = lib.types.package;
      description = "A package whose bin/atc is a pinned atc release (deploy/atc-gateway/versions.env).";
    };

    listen = lib.mkOption {
      type = lib.types.str;
      example = "100.69.47.33:8415";
      description = ''
        The host:port the daemon listens on for gateways: the host's tailnet address and
        port 8415. Passed as --listen, always together with --token-file.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      example = "/var/lib/atc-daemon-secrets/gateway-token";
      description = ''
        A root-only file holding the bearer tokens a gateway may present: one, or two during
        a rotation, one per line, each at least 32 bytes. It is passed in with systemd
        LoadCredential as `gateway-token`, so the service user never reads the file itself.
      '';
    };

    impTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/atc-daemon-secrets/imp-token";
      description = ''
        impd's named token for the daemon (scope manage, imps harness-*), passed in with
        LoadCredential as `imp-token`. An imp target reads it at
        /run/credentials/atc-daemon.service/imp-token.
      '';
    };

    targets = lib.mkOption {
      type = lib.types.attrsOf json.type;
      example = lib.literalExpression ''
        {
          geoffcloud = {
            provider = "imp";
            url = "http://127.0.0.1:7070";
            tokenFile = "/run/credentials/atc-daemon.service/imp-token";
            impPrefix = "harness-";
          };
        }
      '';
      description = "atc's execution targets by name, each a provider and its options, as config.json takes them.";
    };

    defaultTarget = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The target a spawn without one runs on; null leaves it to atc.";
    };

    principals = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.targets = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "The targets this client may use.";
          };
        }
      );
      example = {
        "<client-id>".targets = [ "geoffcloud" ];
      };
      description = ''
        The targets each client may use, keyed by the client ID the gateway forwards. With
        principals set, atc grants a client it does not list no target, so the daemon never
        falls back to running sessions on the host itself.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = unknownGrants == [ ];
        message = "services.atc-daemon.principals grants targets that services.atc-daemon.targets does not define: ${lib.concatStringsSep ", " unknownGrants}";
      }
      {
        assertion = cfg.defaultTarget == null || cfg.targets ? ${cfg.defaultTarget};
        message = "services.atc-daemon.defaultTarget must name one of services.atc-daemon.targets";
      }
    ];

    users.users.atc = {
      isSystemUser = true;
      group = "atc";
      inherit home;
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
        HOME = home;
        XDG_RUNTIME_DIR = "/run/atc-daemon";
      };
      restartTriggers = [ configFile ];
      serviceConfig = {
        ExecStartPre = linkConfig;

        # %d is systemd's $CREDENTIALS_DIRECTORY, which holds the gateway-token credential
        ExecStart = lib.escapeShellArgs [
          "${cfg.package}/bin/atc"
          "daemon"
          "--listen"
          cfg.listen
          "--token-file"
          "%d/gateway-token"
        ];
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
