# Disk read-ahead: sets one disk's read_ahead_kb in place of the value the kernel derives from the
# disk's optimal I/O size (docs/architecture/host/host.md#read-ahead-on-the-root-disk).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.disk-read-ahead;
  readAheadPath = "/sys/block/${cfg.device}/queue/read_ahead_kb";
in
{
  options.services.disk-read-ahead = {
    enable = lib.mkEnableOption "a fixed read-ahead on one disk";

    device = lib.mkOption {
      type = lib.types.str;
      example = "vda";
      description = "The kernel name of the disk, as in /sys/block.";
    };

    kibibytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 128;
      description = "The read-ahead in KiB: 128 is the kernel's default for a disk that reports no optimal I/O size.";
    };
  };

  config = lib.mkIf cfg.enable {
    # each add or change event of the disk, the boot's probe included
    services.udev.extraRules = ''
      ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="${cfg.device}", ATTR{queue/read_ahead_kb}="${toString cfg.kibibytes}"
    '';

    # a switch, which needs no device event; the unit changes with the value, so a switch to a new
    # value starts it again
    systemd.services.disk-read-ahead = {
      description = "${cfg.device} read-ahead of ${toString cfg.kibibytes} KiB";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.bash}/bin/bash -c 'echo ${toString cfg.kibibytes} > ${readAheadPath}'";
      };
    };
  };
}
