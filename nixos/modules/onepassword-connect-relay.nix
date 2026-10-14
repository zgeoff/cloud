# 1Password Connect for imps (GEO-120): a relay on docker0's host address to the Connect Service
# in k3s. The imp broker in imp-host forwards granted requests for op-connect.imp.internal to the
# relay. imp-forward drops imp-host's traffic to the k3s ranges, so the container cannot reach the
# Service itself: the host dials its ClusterIP instead, and the Service pins that ClusterIP
# (infra/cluster/onepassword-connect.ts).
#
# systemd holds the socket and starts the proxy on the first connection, so the socket can wait
# for docker0 (FreeBind) and the proxy dials the ClusterIP from the host. nixos-fw does not trust
# docker0, so the module opens the port there, and an admission in inet cloud_host
# (cloud-host-firewall.nix) narrows it to docker0's subnet and the relay's address. imp's module
# does not fix imp-host's address on docker0, so the admission names the whole subnet: every
# container on docker0, imp's docker proxy and image builds included, can reach the relay.
# Connect's read-only token still gates every request. imp-host reaches the relay on docker0 only
# while imp's IPv6 mode is off: that mode moves imp-host to its own bridge, which neither nixos-fw
# nor cloud_host opens for the relay, so the module asserts the mode is off.
{ config, lib, ... }:
let
  cfg = config.services.onepassword-connect-relay;
in
{
  # the admission below is an option of this module
  imports = [ ./cloud-host-firewall.nix ];

  options.services.onepassword-connect-relay = {
    enable = lib.mkEnableOption "the relay from docker0 to 1Password Connect in k3s";

    address = lib.mkOption {
      type = lib.types.str;
      example = "172.17.0.1";
      description = "docker0's host address, where the relay listens.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      example = 18081;
      description = "The port the relay listens on.";
    };

    allowedSubnet = lib.mkOption {
      type = lib.types.str;
      example = "172.17.0.0/16";
      description = "docker0's subnet, the only source cloud_host admits to the relay.";
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
        message = "the Connect relay assumes imp-host on docker0; services.imp.ipv6.enable moves it to br-imphost";
      }
    ];

    networking.cloudHost.admissions = [
      {
        inherit (cfg) port;
        interface = "docker0";
        sourceCIDR = cfg.allowedSubnet;
        destinationAddress = cfg.address;
      }
    ];
    networking.firewall.interfaces.docker0.allowedTCPPorts = [ cfg.port ];

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
