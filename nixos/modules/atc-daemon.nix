# atc's daemon on a cloud host, for the atc gateway to dial (docs/architecture/workloads/atc-gateway.md).
# It runs `atc daemon --listen <addr> --token-file <credential>`: a gateway presents the
# token, and `principals` decides which execution targets each client reaches. Off by
# default; geoffcloud enables it. Enabling it opens a listener and needs approval.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.atc-daemon;
  topology = import ../topology.nix;
  json = pkgs.formats.json { };
  home = "/var/lib/atc-daemon";

  # atc reads $HOME/.config/atc/config.json; this daemon sets only its targets, principals,
  # agents and auth profiles there
  configFile = json.generate "atc-daemon-config.json" (
    {
      inherit (cfg) targets;
      principals = lib.mapAttrs (_: principal: { inherit (principal) targets; }) cfg.principals;
    }
    // lib.optionalAttrs (cfg.defaultTarget != null) { inherit (cfg) defaultTarget; }
    // lib.optionalAttrs (cfg.agents != null) { inherit (cfg) agents; }
    // lib.optionalAttrs (cfg.authProfiles != { }) { inherit (cfg) authProfiles; }
  );

  # links the store's config where atc looks; atc writes a default config only when
  # none exists, so it leaves the link alone
  linkConfig = pkgs.writeShellScript "atc-daemon-link-config" ''
    set -eu
    mkdir -p ${home}/.config/atc
    ln -sfn ${configFile} ${home}/.config/atc/config.json
  '';

  # atc refuses a --token-file that another user owns or that its group or others may open, and
  # systemd's copy of a credential belongs to root. So before the daemon starts, this script copies
  # the gateway-token credential, as the service user, into the runtime directory: tmpfs, mode 0700,
  # which systemd removes when the service stops.
  stagedTokenFile = "/run/atc-daemon/gateway-token";
  stageGatewayToken = pkgs.writeShellScript "atc-daemon-stage-gateway-token" ''
    set -eu
    umask 077
    install -m 0600 "$CREDENTIALS_DIRECTORY/gateway-token" ${stagedTokenFile}
  '';

  # each auth profile that an agent or one of its MCP servers selects and the config does not
  # define
  unknownProfiles = lib.concatLists (
    lib.mapAttrsToList (
      id: agent:
      let
        selected =
          map (profile: {
            from = id;
            inherit profile;
          }) (agent.auth.profiles or [ ])
          ++ lib.mapAttrsToList (server: options: {
            from = "${id} mcpServers.${server}";
            profile = options.profile or "";
          }) (agent.auth.mcpServers or { });
      in
      map (each: "${each.from} -> ${each.profile}") (
        lib.filter (each: !(cfg.authProfiles ? ${each.profile})) selected
      )
    ) (if cfg.agents == null then { } else cfg.agents)
  );

  # each grant that names a target the config does not define
  unknownGrants = lib.concatLists (
    lib.mapAttrsToList (
      id: principal:
      map (target: "${id} -> ${target}") (
        lib.filter (target: !(cfg.targets ? ${target})) principal.targets
      )
    ) cfg.principals
  );
in
{
  options.services.atc-daemon = {
    enable = lib.mkEnableOption "atc's daemon, reached by the atc gateway";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        A package whose bin/atc is a pinned atc release, byte-identical and unpatched: an
        imp target copies it into each guest. The service binds glibc's loader at
        /lib64/ld-linux-x86-64.so.2 for it.
      '';
    };

    listen = lib.mkOption {
      type = lib.types.str;
      example = "${topology.tailnet.nodes.geoffcloud.address}:${toString topology.atc.daemonPort}";
      description = ''
        The host:port the daemon listens on for gateways: the host's tailnet address and
        atc's daemon port. Passed as --listen, always together with --token-file.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      example = "/var/lib/atc-daemon-secrets/gateway-token";
      description = ''
        A root-only file holding the bearer tokens a gateway may present: one, or two during
        a rotation, one per line, each at least 32 bytes. It is passed in with systemd
        LoadCredential as `gateway-token`, so the service user never reads the file itself.
        When the service starts, systemd copies the file, and the service copies that credential
        to ${stagedTokenFile}, owned by the service user with mode 0600, as atc's --token-file
        needs. So after a rotation run `systemctl restart atc-daemon`: SIGHUP rereads only that
        copy, not this file.
      '';
    };

    impTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/atc-daemon-secrets/imp-token";
      description = ''
        impd's named token for the daemon (scope manage, imps harness-*), passed in with
        LoadCredential as `imp-token`. An imp target reads it at
        /run/credentials/atc-daemon.service/imp-token. As with tokenFile, a new token reaches
        the daemon only after `systemctl restart atc-daemon`.
      '';
    };

    targets = lib.mkOption {
      type = lib.types.attrsOf json.type;
      example = lib.literalExpression ''
        {
          geoffcloud = {
            provider = "imp";
            url = "http://127.0.0.1:${toString topology.imp.apiPort}";
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

    agents = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf json.type);
      default = null;
      example = {
        claude = { };
        codex = { };
      };
      description = ''
        The agents atc offers, keyed by agent id, each as config.json's `agents` takes it. null
        leaves the key out, for atc's default; `{ }` offers no agent, so every spawn fails.
      '';
    };

    authProfiles = lib.mkOption {
      type = lib.types.attrsOf json.type;
      default = { };
      example = {
        github = {
          secret = "github-imp-agents";
          kind = "github";
        };
      };
      description = ''
        The credential profiles an agent's `auth` selects, keyed by profile name, as config.json's
        `authProfiles` takes them. Each names a secret that impd holds, never its value, and impd's
        broker adds the credential on the way out of the imp. The daemon's impd token must list each
        secret as grantable. `{ }` leaves the key out.
      '';
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
        assertion = unknownProfiles == [ ];
        message = "services.atc-daemon.agents select auth profiles that services.atc-daemon.authProfiles does not define: ${lib.concatStringsSep ", " unknownProfiles}";
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
      # atc runs git on this host to resolve a git workspace's ref before an imp clones it
      path = [ pkgs.git ];
      environment = {
        HOME = home;
        XDG_RUNTIME_DIR = "/run/atc-daemon";
      };
      restartTriggers = [ configFile ];
      serviceConfig = {
        ExecStartPre = [
          linkConfig
          stageGatewayToken
        ];

        ExecStart = lib.escapeShellArgs [
          "${cfg.package}/bin/atc"
          "daemon"
          "--listen"
          cfg.listen
          "--token-file"
          stagedTokenFile
        ];
        User = "atc";
        Group = "atc";
        StateDirectory = "atc-daemon";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "atc-daemon";
        RuntimeDirectoryMode = "0700";
        # the release binary asks for the standard loader, which NixOS has nowhere else
        BindReadOnlyPaths = [ "${pkgs.glibc}/lib/ld-linux-x86-64.so.2:/lib64/ld-linux-x86-64.so.2" ];
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
