# Host cgroup CPU: a service writes the user and system CPU time of the host's root cgroup, its
# slices and the units in each slice as node-exporter textfile metrics (host-cgroup-cpu.sh), so a
# spike of system CPU shows which unit, container or kernel work took it. The kubelet's cAdvisor
# reads only the pods' cgroups, and node-exporter's systemd collector exports no CPU time.
# A loop writes the file at each interval, rather than a timer, so the journal that Alloy ships to
# Loki gets no start and stop lines for each write.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.host-cgroup-cpu;
  topology = import ../topology.nix;

  writer = pkgs.writeShellApplication {
    name = "host-cgroup-cpu";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
    ];
    text = builtins.readFile ./host-cgroup-cpu.sh;
  };

  loop = pkgs.writeShellApplication {
    name = "host-cgroup-cpu-loop";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      while true; do
        ${lib.getExe writer}
        sleep ${toString cfg.intervalSeconds}
      done
    '';
  };
in
{
  options.services.host-cgroup-cpu = {
    enable = lib.mkEnableOption "the host cgroup CPU textfile metric";

    textfileDir = lib.mkOption {
      type = lib.types.str;
      default = topology.nodeExporter.textfileDir;
      description = "The directory node-exporter's textfile collector reads.";
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 15;
      description = "How many seconds the loop waits between two writes.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = writer;
      readOnly = true;
      description = "The writer script, exposed for the flake check.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.host-cgroup-cpu = {
      description = "host cgroup CPU textfile metric";
      wantedBy = [ "multi-user.target" ];
      environment.TEXTFILE_DIR = cfg.textfileDir;
      # root, with only the capability that writes into the textfile directory, which
      # services.impd-local-health owns
      serviceConfig = {
        ExecStart = lib.getExe loop;
        Restart = "on-failure";
        RestartSec = "1min";
        MemoryMax = "64M";
        NoNewPrivileges = true;
        CapabilityBoundingSet = "CAP_DAC_OVERRIDE";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateNetwork = true;
        ReadWritePaths = [ cfg.textfileDir ];
      };
    };
  };
}
