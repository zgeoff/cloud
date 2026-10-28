# 1Password Connect for imps (GEO-120): a relay on the host's address on imp-host's bridge,
# Podman's podman0, to the Connect Service in k3s. The imp broker in imp-host forwards granted
# requests for op-connect.imp.internal to the relay. imp-forward drops imp-host's traffic to the k3s ranges, so the container cannot reach the
# Service itself: the host dials its ClusterIP instead, and the Service pins that ClusterIP
# (infra/cluster/onepassword-connect.ts).
#
# systemd holds the socket and starts the proxy on the first connection, so the socket can wait
# for the bridge, which netavark makes only when imp-host starts (FreeBind), and the proxy dials
# the ClusterIP from the host. nixos-fw does not trust the bridge, so the module opens the port
# there, and an admission in inet cloud_host (cloud-host-firewall.nix) narrows it to the bridge's
# subnet and the relay's address. imp's module does not fix imp-host's address on the bridge, so
# the admission names the whole subnet: every container on Podman's default network can reach the
# relay. Connect's read-only token still gates every request. imp-host reaches the relay on
# podman0 only while imp's IPv6 mode is off: that mode moves imp-host to its own bridge,
# br-imphost, which neither nixos-fw nor cloud_host opens for the relay, so the module asserts the
# mode is off.
{ config, lib, ... }:
let
  cfg = config.services.onepassword-connect-relay;
in
{
  # the admission below is an option of this module
  imports = [ ./cloud-host-firewall.nix ];

  options.services.onepassword-connect-relay = {
    enable = lib.mkEnableOption "the relay from imp-host's bridge to 1Password Connect in k3s";

    interface = lib.mkOption {
      type = lib.types.str;
      example = "podman0";
      description = "imp-host's bridge, the interface the relay takes connections on.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      example = "10.88.0.1";
      description = "The host's address on the bridge, where the relay listens.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      example = 18081;
      description = "The port the relay listens on.";
    };

    allowedSubnet = lib.mkOption {
      type = lib.types.str;
      example = "10.88.0.0/16";
      description = "The bridge's subnet, the only source cloud_host admits to the relay.";
    };

    target = lib.mkOption {
      type = lib.types.str;
      example = "10.43.82.198:8000";
      description = "The Connect Service's ClusterIP and port, which the relay dials.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(config.services.imp.ipv6.enable or false);
        message = "the Connect relay assumes imp-host on ${cfg.interface}; services.imp.ipv6.enable moves it to br-imphost";
      }
    ];

    networking.cloudHost.admissions = [
      {
        inherit (cfg) port interface;
        sourceCIDR = cfg.allowedSubnet;
        destinationAddress = cfg.address;
      }
    ];
    # optionalAttrs, not mkIf: the module system reads the names of an attrset inside an mkIf even
    # when its condition is false, and with the relay off the interface option has no value
    networking.firewall.interfaces = lib.optionalAttrs cfg.enable {
      ${cfg.interface}.allowedTCPPorts = [ cfg.port ];
    };

    systemd.sockets.onepassword-connect-relay = {
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "${cfg.address}:${toString cfg.port}" ];
      socketConfig.FreeBind = true;
    };
    systemd.services.onepassword-connect-relay = {
      serviceConfig = {
        ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${cfg.target}";
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
  };
}
