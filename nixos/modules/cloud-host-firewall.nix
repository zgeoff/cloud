# The host's own nftables table, inet cloud_host, beside NixOS's inet nixos-fw: it narrows a TCP
# port that nixos-fw accepts more widely, such as on a trusted interface, to one path. Each
# admission accepts its port only from its interface, IPv4 source range and destination address,
# and drops every other packet to that port. A drop in any input chain is final, and the accept
# only passes the packet on to nixos-fw, so nixos-fw must still open the port for the admitted
# path. The table's input chain runs before nixos-fw's (priority filter - 10). The rules are
# sorted by port, so the table's text does not depend on the order the modules define them in.
{ config, lib, ... }:
let
  cfg = config.networking.cloudHost;
  admissions = lib.sort (a: b: a.port < b.port) cfg.admissions;
  ports = map (admission: admission.port) admissions;
  duplicatePorts = lib.unique (lib.filter (port: lib.count (p: p == port) ports > 1) ports);
  duplicatePortList = lib.concatMapStringsSep ", " toString duplicatePorts;
  # two lines of the input chain, indented as its other lines
  renderAdmission =
    admission:
    let
      port = toString admission.port;
    in
    "  tcp dport ${port} iifname \"${admission.interface}\" ip saddr ${admission.sourceCIDR} ip daddr ${admission.destinationAddress} accept\n"
    + "  tcp dport ${port} drop\n";
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
      The ports inet cloud_host narrows, one admission per port. With none, the module adds no
      table.
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
      {
        assertion = duplicatePorts == [ ];
        message = "networking.cloudHost.admissions admits port ${duplicatePortList} more than once: the first admission's drop would end every later one";
      }
    ];

    networking.nftables.tables.cloud_host = {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority filter - 10; policy accept;
        ${lib.concatMapStrings renderAdmission admissions}}
      '';
    };
  };
}
