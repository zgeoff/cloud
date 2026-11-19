# nixie's model gateway (docs/runbooks/model-gateway.md): one process on the host that
# every model request of production nixie passes. It counts a day and a month in periods.zone,
# refuses past the limits nixie sets on its control listener, and refuses any limit above the caps
# that only this config holds. It listens twice:
#
# - the model listener on imp-host's bridge, where imp-host's broker sends each nixie sandbox's
#   model requests (the impd model secrets' upstream). inet cloud_host admits the bridge's subnet
#   only, as for the preview service's model route.
# - the control listener on the host's loopback, which nixie's server calls with the bearer token
#   in tokenFile. nixie runs in a pod, whose loopback is its own, so a relay takes the pod's
#   connections on the host's tailnet address and dials the loopback listener. inet cloud_host
#   admits the relay's port from pod addresses on cni0 only, as for the atc daemon, so no sandbox
#   and no tailnet device reaches it. The relay's port differs from the control port, because
#   cloud_host drops every packet to an admitted port that no admission names, the loopback's own
#   included.
#
# A plan route (nixie's docs/architecture/policy/model-gateway.md, "The plan route") holds a
# ChatGPT plan login: the gateway refreshes it and sets the access token on each request. Its login
# file lives in the StateDirectory, and its route key, which impd's model secret for the route also
# holds, reaches the unit as a credential like the control token. The unit needs every route key
# file to start.
#
# The store and the override file live in the unit's StateDirectory. `model-gateway raise` writes
# the override as the unit's user (the runbook's command), or the gateway could not read it. The
# unit starts only once the token file exists, so a switch before it is staged skips the unit.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.model-gateway;
  stateDirectory = "/var/lib/model-gateway";
  credentialsDirectory = "/run/credentials/model-gateway.service";
  tokenCredential = "${credentialsDirectory}/control-token";
  # each plan route's key reaches the unit as the credential <route>-route-key
  routeKeyCredential = id: "${id}-route-key";
  loginRoutes = lib.filterAttrs (_: route: route.login != null) cfg.routes;

  priceRateOptions = lib.genAttrs [ "input" "cache_write" "cache_write_1h" "cached_input" "output" ] (
    price:
    lib.mkOption {
      type = lib.types.either lib.types.ints.unsigned lib.types.float;
      description = "The model's ${price} price, in dollars per million tokens.";
    }
  );
  measuresOptions = {
    dollars = lib.mkOption {
      type = lib.types.either lib.types.ints.positive lib.types.float;
      description = "The dollars the period may reach.";
    };
    tokens = lib.mkOption {
      type = lib.types.ints.positive;
      description = "The tokens the period may reach.";
    };
  };

  routeType = lib.types.submodule {
    options = {
      model = lib.mkOption {
        type = lib.types.str;
        example = "claude-sonnet-5-5";
        description = "The one model the route allows; the gateway refuses a request for another.";
      };
      upstream = lib.mkOption {
        type = lib.types.str;
        default = "https://api.anthropic.com";
        description = "The model API's origin, which the gateway sends the route's requests to.";
      };
      providerPin = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "novita/fp8";
        description = "The OpenRouter provider that the profile's provider_pin names; the gateway refuses any other provider field. null for none.";
      };
      api = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "anthropic-messages"
            "openai-responses"
          ]
        );
        default = null;
        description = "The model API the route speaks; null for the gateway's default, anthropic-messages.";
      };
      maxOutputTokens = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 128000;
        description = "The model's largest output, which the gateway assumes for a request that sets no max_output_tokens; an openai-responses route needs it. null for none.";
      };
      login = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              file = lib.mkOption {
                type = lib.types.str;
                example = "/var/lib/model-gateway/chatgpt-login-gpt-6-luna.json";
                description = "The plan login file, which `model-gateway chatgpt-login` writes and the gateway rotates; it lives in the unit's StateDirectory, the one place the unit may write.";
              };
              routeKeyFile = lib.mkOption {
                type = lib.types.str;
                description = "A root-only file holding the route key, one line, which the unit loads as the credential <route>-route-key; impd's model secret for the route holds the same key.";
              };
            };
          }
        );
        default = null;
        description = "The ChatGPT plan login the route holds, which makes it a plan route; null for none.";
      };
      prices = lib.mkOption {
        type = lib.types.submodule {
          options = priceRateOptions // {
            long_prompt = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.submodule {
                  options = priceRateOptions // {
                    over_tokens = lib.mkOption {
                      type = lib.types.ints.positive;
                      example = 100000;
                      description = "The prompt length, in tokens, past which a call costs these prices.";
                    };
                  };
                }
              );
              default = null;
              description = "The prices of a call whose prompt passes over_tokens; null for none.";
            };
          };
        };
        description = "The model's list prices, which the gateway prices each reply at.";
      };
    };
  };

  # the gateway's config schema is strict and takes no null for an absent key, so each optional key
  # renders only when set
  renderRoute =
    id: route:
    {
      inherit (route) model upstream;
      prices = lib.filterAttrs (_: rates: rates != null) route.prices;
    }
    // lib.optionalAttrs (route.providerPin != null) { inherit (route) providerPin; }
    // lib.optionalAttrs (route.api != null) { inherit (route) api; }
    // lib.optionalAttrs (route.maxOutputTokens != null) { inherit (route) maxOutputTokens; }
    // lib.optionalAttrs (route.login != null) {
      login = {
        inherit (route.login) file;
        routeKeyFile = "${credentialsDirectory}/${routeKeyCredential id}";
      };
    };

  # YAML is a superset of JSON, and the gateway parses its config with Bun.YAML
  configFile = pkgs.writeText "model-gateway.yaml" (
    builtins.toJSON {
      listen = {
        hostname = cfg.modelListen.address;
        inherit (cfg.modelListen) port;
      };
      store = "${stateDirectory}/store.json";
      periods.zone = cfg.zone;
      inherit (cfg) caps;
      control = {
        listen = {
          hostname = "127.0.0.1";
          port = cfg.control.port;
        };
        tokenFile = tokenCredential;
      };
      countBySandbox = true;
      override = "${stateDirectory}/override.json";
      routes = lib.mapAttrs renderRoute cfg.routes;
    }
  );

  relayListen = "${cfg.controlRelay.address}:${toString cfg.controlRelay.port}";
in
{
  imports = [ ./cloud-host-firewall.nix ];

  options.services.model-gateway = {
    enable = lib.mkEnableOption "nixie's model gateway, which counts and caps production nixie's model spend";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../packages/model-gateway.nix { };
      description = "The package whose bin/model-gateway is nixie's model gateway.";
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = configFile;
      description = "The rendered config, which the unit and `model-gateway raise` read.";
    };

    zone = lib.mkOption {
      type = lib.types.str;
      example = "Australia/Sydney";
      description = "The IANA zone whose midnight resets the day and the month; nixie's time zone.";
    };

    caps = {
      day = measuresOptions;
      month = measuresOptions;
    };

    modelListen = {
      interface = lib.mkOption {
        type = lib.types.str;
        example = "podman0";
        description = "imp-host's bridge, the interface the model listener takes requests on.";
      };
      address = lib.mkOption {
        type = lib.types.str;
        example = "10.88.0.1";
        description = "The host's address on the bridge, where the model listener listens.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        example = 8789;
        description = "The model listener's port.";
      };
      allowedSubnet = lib.mkOption {
        type = lib.types.str;
        example = "10.88.0.0/16";
        description = "The bridge's subnet, the only source cloud_host admits to the model listener.";
      };
    };

    control = {
      port = lib.mkOption {
        type = lib.types.port;
        example = 8790;
        description = "The control listener's port on 127.0.0.1.";
      };
      tokenFile = lib.mkOption {
        type = lib.types.str;
        description = "A root-only file holding the control token, one line, as nixie's secrets file does.";
      };
    };

    controlRelay = {
      interface = lib.mkOption {
        type = lib.types.str;
        example = "cni0";
        description = "The pods' bridge, the interface the relay takes nixie's connections on.";
      };
      address = lib.mkOption {
        type = lib.types.str;
        example = "100.64.0.10";
        description = "The host's tailnet address, which nixie's pod dials for the control listener.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        example = 8791;
        description = "The relay's port; it must differ from control.port.";
      };
      allowedSubnet = lib.mkOption {
        type = lib.types.str;
        example = "10.42.0.0/16";
        description = "The pods' range, the only source cloud_host admits to the relay.";
      };
    };

    routes = lib.mkOption {
      type = lib.types.attrsOf routeType;
      description = "One route per nixie model profile, keyed by the profile's ID.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.routes != { };
        message = "services.model-gateway.routes names no route, and the gateway needs one.";
      }
      {
        assertion = cfg.controlRelay.port != cfg.control.port;
        message = "services.model-gateway.controlRelay.port must differ from control.port: cloud_host drops the loopback's packets to an admitted port.";
      }
      {
        assertion = lib.all (route: route.api == "openai-responses") (lib.attrValues loginRoutes);
        message = "services.model-gateway.routes: a route with a login speaks openai-responses, the API of ChatGPT's Codex backend.";
      }
      {
        assertion = lib.all (route: lib.hasPrefix "${stateDirectory}/" route.login.file) (
          lib.attrValues loginRoutes
        );
        message = "services.model-gateway.routes: a login file lives in ${stateDirectory}, the only folder the unit may write, because each refresh rewrites it.";
      }
      {
        assertion = !(config.services.imp.ipv6.enable or false);
        message = "the model gateway's listener assumes imp-host on ${cfg.modelListen.interface}; services.imp.ipv6.enable moves it to br-imphost";
      }
    ];

    networking.cloudHost.admissions = [
      {
        inherit (cfg.modelListen) port interface;
        sourceCIDR = cfg.modelListen.allowedSubnet;
        destinationAddress = cfg.modelListen.address;
      }
      {
        inherit (cfg.controlRelay) port interface;
        sourceCIDR = cfg.controlRelay.allowedSubnet;
        destinationAddress = cfg.controlRelay.address;
      }
    ];
    # nixos-fw does not trust podman0, so it opens the model port there; it opens the relay's port
    # on its interface too, so the relay does not depend on nixos-fw trusting the pods' bridge
    networking.firewall.interfaces = lib.mkMerge [
      { ${cfg.modelListen.interface}.allowedTCPPorts = [ cfg.modelListen.port ]; }
      { ${cfg.controlRelay.interface}.allowedTCPPorts = [ cfg.controlRelay.port ]; }
    ];

    users.users.model-gateway = {
      isSystemUser = true;
      group = "model-gateway";
    };
    users.groups.model-gateway = { };

    environment.systemPackages = [ cfg.package ];

    systemd.services.model-gateway = {
      description = "nixie's model gateway";
      wantedBy = [ "multi-user.target" ];
      # the model listener binds imp-host's bridge, which netavark makes only when imp-host starts
      after = [
        "network-online.target"
        "imp-host.service"
      ];
      wants = [
        "network-online.target"
        "imp-host.service"
      ];
      unitConfig.ConditionPathExists = cfg.control.tokenFile;
      restartTriggers = [ configFile ];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/model-gateway serve --config ${configFile}";
        User = "model-gateway";
        Group = "model-gateway";
        StateDirectory = "model-gateway";
        StateDirectoryMode = "0700";
        # a missing route key file fails the unit's start, as a missing token would
        LoadCredential = [
          "control-token:${cfg.control.tokenFile}"
        ]
        ++ lib.mapAttrsToList (
          id: route: "${routeKeyCredential id}:${route.login.routeKeyFile}"
        ) loginRoutes;
        # the bridge address appears only once imp-host runs, so a failed bind retries
        Restart = "always";
        RestartSec = 5;
        # the gateway lets each reply under way finish for up to 30 s before it exits
        TimeoutStopSec = 45;
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

    # The relay to the control listener. systemd holds the socket and starts the proxy on the first
    # connection, so the socket can wait for the tailnet address (FreeBind).
    systemd.sockets.model-gateway-control-relay = {
      description = "the model gateway's control relay socket";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ relayListen ];
      socketConfig.FreeBind = true;
    };
    systemd.services.model-gateway-control-relay = {
      description = "the model gateway's control relay";
      partOf = [ "model-gateway-control-relay.socket" ];
      serviceConfig = {
        ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${toString cfg.control.port}";
        DynamicUser = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        CapabilityBoundingSet = "";
      };
    };
    # switch-to-configuration never restarts a changed socket unit (nixpkgs#74899), so a switch
    # that moves the relay's address restarts this unit instead, and it restarts the socket
    systemd.services.model-gateway-control-relay-listen = {
      description = "the model gateway's control relay socket on its listen address";
      wantedBy = [ "multi-user.target" ];
      after = [ "model-gateway-control-relay.socket" ];
      restartTriggers = [ relayListen ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${config.systemd.package}/bin/systemctl restart model-gateway-control-relay.socket";
      };
    };
  };
}
