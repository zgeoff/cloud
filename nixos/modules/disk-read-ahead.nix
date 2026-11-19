# Disk read-ahead: sets each listed disk's read_ahead_kb in place of the value the kernel derives
# from the disk's optimal I/O size (docs/architecture/host/host.md#disk-read-ahead).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.disk-read-ahead;
  kibibytes = toString cfg.kibibytes;

  # a name with a slash is a link that an earlier udev rule makes, such as ZFS's 60-zvol.rules
  matchDevice =
    device: if lib.hasInfix "/" device then ''SYMLINK=="${device}"'' else ''KERNEL=="${device}"'';

  # a disk that is not there yet gets its value from the rule at its add event; the rancher zvol
  # appears only after tank/cloud's key loads
  setReadAhead = pkgs.writeShellScript "set-disk-read-ahead" ''
    set -euo pipefail
    for device in ${lib.escapeShellArgs cfg.devices}; do
      if [ ! -e "/dev/$device" ]; then
        echo "/dev/$device is absent: the udev rule sets its read-ahead when it appears"
        continue
      fi
      name=$(${pkgs.coreutils}/bin/basename "$(${pkgs.coreutils}/bin/readlink -f "/dev/$device")")
      echo ${kibibytes} > "/sys/block/$name/queue/read_ahead_kb"
    done
  '';
in
{
  options.services.disk-read-ahead = {
    enable = lib.mkEnableOption "a fixed read-ahead on some disks";

    devices = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      example = [
        "vda"
        "zvol/tank/cloud/rancher"
      ];
      description = "Each disk, as its name under /dev: a kernel name, as in /sys/block, or a link that an earlier udev rule makes, such as a zvol's.";
    };

    kibibytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 128;
      description = "The read-ahead in KiB: 128 is the kernel's default for a disk that reports no optimal I/O size.";
    };
  };

  config = lib.mkIf cfg.enable {
    # each add or change event of a disk, the boot's probe included
    services.udev.extraRules = lib.concatMapStrings (device: ''
      ACTION=="add|change", SUBSYSTEM=="block", ${matchDevice device}, ATTR{queue/read_ahead_kb}="${kibibytes}"
    '') cfg.devices;

    # boot, and a switch that adds the unit or changes its value, with no device event needed
    systemd.services.disk-read-ahead = {
      description = "Disk read-ahead of ${kibibytes} KiB";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = setReadAhead;
      };
    };
  };
}
