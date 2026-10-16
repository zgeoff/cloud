# imp's dataset as an encryption root: docs/runbooks/tank-imp-encryption.md moves tank/imp into
# an encrypted copy keyed by tank/cloud's key file, and this module loads its key at boot, with no
# one present.
#
# The pool's import unit loads no key (modules/tank-cloud.nix turns that off), so imp-dataset-key
# loads tank/imp's after the import and before imp's module checks the dataset. It fails when the
# dataset is missing, or is not its own encryption root, or its key does not load. imp's
# imp-zfs-dataset then never runs, so it never makes a plain tank/imp in place of the encrypted
# one, and imp-host, which requires it, stays stopped while the host still reaches SSH.
{ config, lib, ... }:
let
  cfg = config.services.imp-dataset-key;
  imp = config.services.imp.zfs;
in
{
  options.services.imp-dataset-key = {
    enable = lib.mkEnableOption "the boot unlock of imp's encrypted dataset";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.imp.enable && config.services.imp.storage == "zfs";
        message = "services.imp-dataset-key needs services.imp on ZFS";
      }
    ];

    systemd.services.imp-dataset-key = {
      description = "Load the key of ZFS encryption root ${imp.root}";
      requires = [ "zfs-import-${imp.pool}.service" ];
      after = [ "zfs-import-${imp.pool}.service" ];
      requiredBy = [ "imp-zfs-dataset.service" ];
      before = [ "imp-zfs-dataset.service" ];
      path = [ config.boot.zfs.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # zfs load-key reads the file that the dataset's keylocation names
      script = ''
        root=${lib.escapeShellArg imp.root}
        if ! encryption_root=$(zfs get -H -o value encryptionroot "$root"); then
          echo "imp-dataset-key: $root is missing; imp's module would make a plain one" >&2
          exit 1
        fi
        if [ "$encryption_root" != "$root" ]; then
          echo "imp-dataset-key: $root is not its own encryption root (encryptionroot $encryption_root)" >&2
          exit 1
        fi
        if [ "$(zfs get -H -o value keystatus "$root")" != available ]; then
          zfs load-key "$root"
        fi
      '';
    };
  };
}
