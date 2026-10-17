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
# points on the root disk. After the key is restored, starting tank-cloud.target loads it and
# mounts every dataset, since the target requires each mount and each mount its key unit.
#
# binds put a directory of a dataset at a path the services already read, such as
# /var/lib/imp-host/secrets, as a nofail bind mount that requires its dataset's mount. Without
# the key, the dataset is not mounted, so the bind is not made and the path stays the empty
# directory on the root disk; a service that names the bind in requiredBy then refuses to start.
# The module never creates a bind's source directory: tmpfiles could run before the nofail
# dataset mount and create it on the root disk, so the operator makes it on the dataset
# (scripts/host/move-host-secrets.sh seed, docs/runbooks/move-host-secrets.md).
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
  bindSource =
    bind:
    mountPoint bind.dataset + lib.optionalString (bind.subdirectory != "") "/${bind.subdirectory}";
  bindUnit = bind: "${utils.escapeSystemdPath bind.path}.mount";
  # a requiredBy name is a dataset or a bind; either gives the path to wait for
  pathOf = name: if cfg.binds ? ${name} then cfg.binds.${name}.path else mountPoint name;
  zfs = config.boot.zfs.package;
in
{
  options.services.tank-cloud = {
    enable = lib.mkEnableOption "the encrypted tank/cloud datasets, unlocked and mounted at boot";

    binds = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            dataset = lib.mkOption {
              type = lib.types.enum [
                "host-secrets"
                "imp-db-backups"
              ];
              description = "The dataset whose mount point holds the bind's source directory.";
            };
            subdirectory = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "The directory of the dataset to bind; empty binds the dataset's root.";
            };
            path = lib.mkOption {
              type = lib.types.str;
              description = "Where the source directory appears.";
            };
          };
        }
      );
      default = { };
      example = {
        imp-host-secrets = {
          dataset = "host-secrets";
          subdirectory = "imp-host";
          path = "/var/lib/imp-host/secrets";
        };
      };
      description = ''
        Bind mounts of directories of the datasets, each named so that requiredBy can refer to
        it. A bind is nofail, and requires its dataset's mount.
      '';
    };

    requiredBy = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf (lib.types.enum (datasets ++ lib.attrNames cfg.binds)));
      default = { };
      example = {
        k3s = [ "rancher" ];
      };
      description = ''
        The systemd services that must not start without a tank/cloud dataset, each with the
        datasets and binds it needs. Each one gets RequiresMountsFor on their paths, so it stays
        stopped when the key fails to load.
      '';
    };

    fileSystems = lib.mkOption {
      type = lib.types.attrs;
      internal = true;
      readOnly = true;
      description = ''
        The datasets' and binds' entries for fileSystems. A NixOS test VM replaces fileSystems with
        virtualisation.fileSystems, so the module's check gives them to the VM from here.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # tank-cloud-key loads tank/cloud's key; the import only imports the pool
    boot.zfs.requestEncryptionCredentials = false;

    fileSystems = cfg.fileSystems;

    services.tank-cloud.fileSystems = {
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
    }
    // lib.mapAttrs' (
      _: bind:
      lib.nameValuePair bind.path {
        device = bindSource bind;
        fsType = "none";
        options = [
          "bind"
          "nofail"
        ];
        # NixOS turns depends into x-systemd.requires-mounts-for, so the bind never binds the
        # empty mount point on the root disk
        depends = [ (mountPoint bind.dataset) ];
      }
    ) cfg.binds;

    # every dataset mounted: the recovery after a restored key starts it, because the services
    # pull in only the mounts they need
    systemd.targets.tank-cloud = {
      description = "ZFS encryption root ${root} mounted";
      requires = map mountUnit datasets ++ map bindUnit (lib.attrValues cfg.binds);
      after = map mountUnit datasets ++ map bindUnit (lib.attrValues cfg.binds);
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
      unitConfig.RequiresMountsFor = map pathOf needed;
    }) cfg.requiredBy;
  };
}
