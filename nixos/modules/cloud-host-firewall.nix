# The host's own nftables table, inet cloud_host, beside NixOS's inet nixos-fw: it narrows a TCP
# port that nixos-fw accepts more widely, such as on a trusted interface, to its admitted paths.
# Each admission accepts its port from its interface, IPv4 source range and destination address,
# and after a port's last admission the chain drops every other packet to that port. A drop in
# any input chain is final, and an accept only passes the packet on to nixos-fw, so nixos-fw must
# still open the port for each admitted path. The table's input chain runs before nixos-fw's
# (priority filter - 10). The rules are sorted by port, then interface and source, so the table's
# text does not depend on the order the modules define them in.
{ config, lib, ... }:
let
  cfg = config.networking.cloudHost;
  toSortKey = admission: "${admission.interface} ${admission.sourceCIDR}";
  admissions = lib.sort (
    a: b: if a.port == b.port then toSortKey a < toSortKey b else a.port < b.port
  ) cfg.admissions;
  ports = lib.unique (map (admission: admission.port) admissions);
  # a line of the input chain, indented as its other lines
  renderAccept =
    admission:
    "  tcp dport ${toString admission.port} iifname \"${admission.interface}\" ip saddr ${admission.sourceCIDR} ip daddr ${admission.destinationAddress} accept\n";
  # each of the port's accepts, then the drop of every other packet to it
  renderPort =
    port:
    lib.concatMapStrings renderAccept (lib.filter (admission: admission.port == port) admissions)
    + "  tcp dport ${toString port} drop\n";
in
{
  options.networking.cloudHost.admissions = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          port = lib.mkOption {
            type = lib.types.port;
            description = "The TCP port the admission narrows.";
          };
          interface = lib.mkOption {
            type = lib.types.str;
            example = "cni0";
            description = "The interface the admitted packets enter on.";
          };
          sourceCIDR = lib.mkOption {
            type = lib.types.str;
            example = "10.42.0.0/16";
            description = "The IPv4 range the admitted packets come from.";
          };
          destinationAddress = lib.mkOption {
            type = lib.types.str;
            example = "172.17.0.1";
            description = "The host address the admitted packets go to.";
          };
        };
      }
    );
    default = [ ];
    description = ''
      The paths inet cloud_host admits, one admission per path. A port with several admissions
      accepts each path and drops every other packet. With none, the module adds no table.
    '';
  };

  config = lib.mkIf (cfg.admissions != [ ]) {
    assertions = [
      {
        assertion = config.networking.nftables.enable;
        message = "networking.cloudHost.admissions needs networking.nftables.enable: inet cloud_host is an nftables table";
      }
      {
        assertion = !config.networking.nftables.flushRuleset;
        message = "networking.cloudHost.admissions needs networking.nftables.flushRuleset off: a flush drops the tables of imp, k3s and Docker";
      }
    ];

    networking.nftables.tables.cloud_host = {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority filter - 10; policy accept;
        ${lib.concatMapStrings renderPort ports}}
      '';
    };
  };
}
