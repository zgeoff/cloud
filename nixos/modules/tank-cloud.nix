# tank/cloud: the encrypted datasets on the ZFS pool that hold host state kept out of the root
# disk's snapshots. docs/runbooks/tank-cloud.md creates them on the pool; this module unlocks and
# mounts them at boot, with no one present, and keeps the services that need them stopped when
# the unlock fails.
#
# tank/cloud is the encryption root, with keylocation=file:///var/lib/zfs-keys/tank.key. Its
# children are host-secrets and imp-db-backups, legacy-mounted filesystems, and rancher, a
# sparse zvol that holds ext4. Each one is declared in fileSystems under /var/lib/tank-cloud.
#
# The pool's import unit loads no key here: tank-cloud-key loads tank/cloud's, after the import
# and before every mount. A missing or wrong key then fails that unit alone, with the import
# still green and tank/imp untouched. Every mount requires tank-cloud-key, so it fails at once,
# and every mount is nofail, so local-fs.target never waits on it and the host still reaches
# multi-user and SSH. Each service named in requiredBy carries RequiresMountsFor on its
# datasets, so it fails to start, rather than start on the empty directories under the mount
# points on the root disk. After the key is restored, starting those services loads it and
# mounts the datasets, since each start pulls its mounts and their key unit in again.
{
  config,
  lib,
  utils,
  ...
}:
let
  cfg = config.services.tank-cloud;
  pool = "tank";
  root = "${pool}/cloud";
  mountRoot = "/var/lib/tank-cloud";
  datasets = [
    "host-secrets"
    "imp-db-backups"
    "rancher"
  ];
  mountPoint = dataset: "${mountRoot}/${dataset}";
  mountUnit = dataset: "${utils.escapeSystemdPath (mountPoint dataset)}.mount";
  zfs = config.boot.zfs.package;
in
{
  options.services.tank-cloud = {
    enable = lib.mkEnableOption "the encrypted tank/cloud datasets, unlocked and mounted at boot";

    requiredBy = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf (lib.types.enum datasets));
      default = { };
      example = {
        k3s = [ "rancher" ];
      };
      description = ''
        The systemd services that must not start without a tank/cloud dataset, each with the
        datasets it needs. Each one gets RequiresMountsFor on their mount points, so it stays
        stopped when the key fails to load.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # tank-cloud-key loads tank/cloud's key; the import only imports the pool
    boot.zfs.requestEncryptionCredentials = false;

    fileSystems = {
      ${mountPoint "host-secrets"} = {
        device = "${root}/host-secrets";
        fsType = "zfs";
        options = [ "nofail" ];
      };
      ${mountPoint "imp-db-backups"} = {
        device = "${root}/imp-db-backups";
        fsType = "zfs";
        options = [ "nofail" ];
      };
      # the zvol's device appears once the key is loaded; the weekly fstrim (services.fstrim,
      # on by default) hands the blocks ext4 frees back to the pool
      ${mountPoint "rancher"} = {
        device = "/dev/zvol/${root}/rancher";
        fsType = "ext4";
        options = [ "nofail" ];
      };
    };

    systemd.services = {
      tank-cloud-key = {
        description = "Load the key of ZFS encryption root ${root}";
        requires = [ "zfs-import-${pool}.service" ];
        after = [ "zfs-import-${pool}.service" ];
        requiredBy = map mountUnit datasets;
        before = map mountUnit datasets;
        path = [ zfs ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # zfs load-key reads the file that the dataset's keylocation names, and fails when it is
        # missing or is not 64 hex characters
        script = ''
          if [ "$(zfs get -H -o value keystatus ${root})" != available ]; then
            zfs load-key ${root}
          fi
        '';
      };
    }
    // lib.mapAttrs (_: needed: {
      unitConfig.RequiresMountsFor = map mountPoint needed;
    }) cfg.requiredBy;
  };
}
