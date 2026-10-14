# tank/cloud

`tank/cloud` is the encryption root on geoffcloud's ZFS pool for host state that must stay out of
the root disk's snapshots. Its key sits on `vda` at `/var/lib/zfs-keys/tank.key`, and its data sits
on `vdb`, so neither disk alone exposes the data. The host loads the key at boot with no one present
and mounts three children under `/var/lib/tank-cloud`: the filesystems `host-secrets` and
`imp-db-backups`, and the sparse zvol `rancher`, which holds ext4. When the key fails to load, the
host still boots to SSH, and k3s, imp-host and the atc daemon stay stopped, so none of them starts
on an empty mount point on `vda`.

The NixOS module `nixos/modules/tank-cloud.nix` does the unlock and the mounts. It never creates the
datasets: you create them once with the commands below, before the first switch to a config that
enables it. The `tank-cloud-unlock` check boots a VM through those commands, a reboot, a reboot
without the key and a restored key.

## Create the datasets

**CAUTION:** A switch to a config that enables `services.tank-cloud` while `tank/cloud` does not
exist leaves k3s, imp-host and the atc daemon stopped. Create the datasets before that switch.

Run these on geoffcloud, as root, over `ssh root@geoffcloud`.

1. Check the key file without printing it:

   ```bash
   stat -c '%U %a %s' /var/lib/zfs-keys/tank.key
   ```

   Expect `root 400 64`: 64 hex characters with no newline.

2. Check that the pool can hold an encrypted dataset and that `tank/cloud` does not exist yet:

   ```bash
   zpool get -H -o value feature@encryption tank
   zfs list tank/cloud
   ```

   Expect `enabled` or `active`, then `cannot open 'tank/cloud': dataset does not exist`.

3. Create the encryption root and its children:

   ```bash
   zfs create -o encryption=aes-256-gcm -o keyformat=hex \
     -o keylocation=file:///var/lib/zfs-keys/tank.key -o compression=lz4 -o mountpoint=legacy tank/cloud
   zfs create -o mountpoint=legacy tank/cloud/host-secrets
   zfs create -o mountpoint=legacy tank/cloud/imp-db-backups
   zfs create -s -V 64G tank/cloud/rancher
   ```

   `zfs create` loads the key of a new encryption root, so the children need no `load-key`. The
   children inherit the encryption and the compression. LZ4 stores the blocks of zeros that ext4
   writes as holes. The zvol is sparse, so its size is a cap, not a reservation: `/var/lib/rancher`
   held 11 GB when the zvol was sized, and 64 GB leaves room for the k3s datastore, its images and
   its volumes to grow several times over. Grow it later with `zfs set volsize` and `resize2fs`.

4. Make the ext4 filesystem on the zvol:

   **CAUTION:** `mkfs.ext4` erases the device it is given. Check the path names the new zvol.

   ```bash
   udevadm settle
   mkfs.ext4 -q -L tank-cloud-rancher /dev/zvol/tank/cloud/rancher
   ```

5. Check the result:

   ```bash
   zfs get -H -o name,property,value encryption,keyformat,keylocation,keystatus,mountpoint -r tank/cloud
   ```

   Expect `aes-256-gcm`, `hex` and `available` on all four, the key file's URL on `tank/cloud`, and
   `legacy` on `tank/cloud` and its two filesystems.

## Switch and check

1. Switch with `bash scripts/switch-geoffcloud.sh`, as [Workflows](./workflows.md#switch-the-host)
   describes. The switch restarts k3s, imp-host and the atc daemon, because their units gain the
   mount requirement, so imp-host's restart puts every awake imp to sleep.
2. Check the mounts and the services:

   ```bash
   for path in /var/lib/tank-cloud/{host-secrets,imp-db-backups,rancher}; do
     findmnt -n -o SOURCE,FSTYPE --mountpoint "$path"
   done
   systemctl is-active tank-cloud-key k3s imp-host atc-daemon
   ```

   Expect `tank/cloud/host-secrets zfs`, `tank/cloud/imp-db-backups zfs` and a `/dev/zd<n> ext4`
   line, then `active` four times.

3. Make the two filesystems root-only, because they hold secrets:

   ```bash
   chmod 0700 /var/lib/tank-cloud/host-secrets /var/lib/tank-cloud/imp-db-backups
   ```

After a reboot, `zfs get -H -o value encryption,keystatus tank/cloud` prints `aes-256-gcm` and
`available`.

## If the key fails to load at boot

The unit `tank-cloud-key` fails, and its journal holds the reason, such as
`Failed to open key material file` for a missing key file. The host stays reachable over SSH, and
k3s, imp-host and the atc daemon stay stopped. The datasets keep their data.

1. Restore the key from the 1Password item `zfs-tank-key`. The key travels on SSH's stdin, never on
   a command line, because Tailscale SSH logs each command line:

   ```bash
   op read --no-newline op://cloud/zfs-tank-key/password | ssh root@geoffcloud \
     'install -d -m 0700 /var/lib/zfs-keys && (umask 077 && cat > /var/lib/zfs-keys/tank.key) && chmod 0400 /var/lib/zfs-keys/tank.key && test "$(wc -c < /var/lib/zfs-keys/tank.key)" -eq 64 && echo ok'
   ```

   Expect `ok`. Without `ok`, the key is not 64 characters: check the item, and never write the key
   with a trailing newline.

2. Mount the datasets and start the services:
   `ssh root@geoffcloud systemctl start tank-cloud.target k3s imp-host atc-daemon`. The target
   requires every mount, and each mount loads the key again. The services alone would mount only the
   datasets they need, and leave `imp-db-backups` unmounted.
3. Check as in [Switch and check](#switch-and-check).
