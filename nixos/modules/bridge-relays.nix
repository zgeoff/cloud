# Relays from imp-host's bridge, Podman's podman0, to Services in k3s. Each instance of
# services.bridge-relays is one relay: the imp broker in imp-host forwards granted requests for a
# made-up host name (op-connect.imp.internal, pepys.imp.internal, boxxy.imp.internal) to the relay's
# port on the host's address on the bridge, and the relay dials the Service. imp-forward drops
# imp-host's traffic to the k3s ranges, so the container cannot reach a Service itself: the host
# dials its ClusterIP instead, and each Service pins that ClusterIP (infra/cluster/).
#
# systemd holds each socket and starts the proxy on the first connection, so the socket can wait
# for the bridge, which netavark makes only when imp-host starts (FreeBind), and the proxy dials
# the ClusterIP from the host. nixos-fw does not trust the bridge, so the module opens each port
# there, and an admission in inet cloud_host (cloud-host-firewall.nix) narrows it to the bridge's
# subnet and the relay's address. imp's module does not fix imp-host's address on the bridge, so
# the admission names the whole subnet: every container on Podman's default network can reach each
# relay. The Service's own token still gates every request. imp-host reaches a relay on podman0
# only while imp's IPv6 mode is off: that mode moves imp-host to its own bridge, br-imphost, which
# neither nixos-fw nor cloud_host opens for the relay, so the module asserts the mode is off.
#
# An instance named N makes the units N.socket, N.service and N-listen.service.
{ config, lib, ... }:
let
  relays = config.services.bridge-relays;
  listenStreams = relay: [ "${relay.address}:${toString relay.port}" ];
in
{
  # the admission below is an option of this module
  imports = [ ./cloud-host-firewall.nix ];

  options.services.bridge-relays = lib.mkOption {
    default = { };
    description = "The relays from imp-host's bridge to Services in k3s, by name.";
    example = lib.literalExpression ''
      {
        onepassword-connect-relay = {
          interface = "podman0";
          address = "10.88.0.1";
          port = 18081;
          allowedSubnet = "10.88.0.0/16";
          target = "10.43.82.198:8000";
        };
      }
    '';
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            label = lib.mkOption {
              type = lib.types.str;
              default = "the relay ${name}";
              example = "the Connect relay";
              description = "What the relay's unit descriptions and assertion message call it.";
            };

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
              description = "The Service's ClusterIP and port, which the relay dials.";
            };
          };
        }
      )
    );
  };

  config = {
    assertions = lib.mapAttrsToList (_: relay: {
      assertion = !(config.services.imp.ipv6.enable or false);
      message = "${relay.label} assumes imp-host on ${relay.interface}; services.imp.ipv6.enable moves it to br-imphost";
    }) relays;

    networking.cloudHost.admissions = lib.mapAttrsToList (_: relay: {
      inherit (relay) port interface;
      sourceCIDR = relay.allowedSubnet;
      destinationAddress = relay.address;
    }) relays;

    # mkMerge over the instances, not an mkIf: with no relay there is no interface to name
    networking.firewall.interfaces = lib.mkMerge (
      lib.mapAttrsToList (_: relay: { ${relay.interface}.allowedTCPPorts = [ relay.port ]; }) relays
    );

    systemd.sockets = lib.mapAttrs (_: relay: {
      wantedBy = [ "sockets.target" ];
      listenStreams = listenStreams relay;
      socketConfig.FreeBind = true;
    }) relays;

    systemd.services =
      # switch-to-configuration never restarts a changed socket unit (nixpkgs#74899), so a switch
      # that moves the listen address restarts this unit instead, and it restarts the socket
      lib.mapAttrs' (
        name: relay:
        lib.nameValuePair "${name}-listen" {
          description = "${relay.label}'s socket on its listen address";
          wantedBy = [ "multi-user.target" ];
          after = [ "${name}.socket" ];
          restartTriggers = listenStreams relay;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${config.systemd.package}/bin/systemctl restart ${name}.socket";
          };
        }
      ) relays
      // lib.mapAttrs (name: relay: {
        # the proxy holds the listening socket it was started with, so it stops with the socket
        partOf = [ "${name}.socket" ];
        serviceConfig = {
          ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${relay.target}";
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
      }) relays;
  };
}
