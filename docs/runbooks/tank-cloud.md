# tank/cloud

`tank/cloud` is the encryption root on geoffcloud's ZFS pool for host state that must stay out of
the root disk's snapshots. Its key sits on `vda` at `/var/lib/zfs-keys/tank.key`, and its data sits
on `vdb`, so neither disk alone exposes the data. The host loads the key at boot with no one present
and mounts its three children: the filesystems `host-secrets` and `imp-db-backups` under
`/var/lib/tank-cloud`, and the zvol `rancher`, which holds ext4, at `/var/lib/rancher`, k3s's data
directory. When the key fails to load, the host still boots to SSH, and k3s, imp-host and the atc
daemon stay stopped, so none of them starts on an empty mount point on `vda`.

The NixOS module `nixos/modules/tank-cloud.nix` does the unlock and the mounts. It never creates the
datasets: you create them once with the commands below, before the first switch to a config that
enables it. The `tank-cloud-unlock` check boots a VM through those commands, a reboot, a reboot
without the key and a restored key.

The secret files of imp-host and the atc daemon and impd's database copies keep their paths and live
on these datasets: the module bind-mounts the directories `imp-host` and `atc-daemon` of
`host-secrets` at `/var/lib/imp-host/secrets` and `/var/lib/atc-daemon-secrets`, and the root of
`imp-db-backups` at `/root/imp-db-backups`. A bind is `nofail` and requires its dataset's mount, so
without the key it is not made, and the path stays the empty directory on `vda`.
`scripts/install-imp-dns-token.sh` and `copy-impd-db-host` each refuse to write while their bind is
not mounted, so neither writes onto `vda`.

The zvol holds k3s's datastore, with every Kubernetes Secret, the agent and kubelet keys and every
cluster volume, at `/var/lib/rancher`. The module bind-mounts the zvol's directory `etc-rancher` at
`/etc/rancher`, which holds the admin kubeconfig and the node password. `/var/lib/kubelet` stays on
`vda`.

`tank/imp`, which holds everything impd keeps on the pool, is an encryption root of its own, keyed
by the same file. The NixOS module `nixos/modules/imp-dataset-key.nix` loads its key at boot, after
the pool's import and before imp's module checks the dataset. When `tank/imp` is missing, plain or
locked, the unit fails and imp-host stays stopped, so imp's module never makes a plain `tank/imp`.
The `imp-dataset-key` check boots a VM through a missing dataset, a reboot with the key, a reboot
without it and a restored key.

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
   zfs create -V 20G tank/cloud/rancher
   ```

   `zfs create` loads the key of a new encryption root, so the children need no `load-key`. The
   children inherit the encryption and the compression. LZ4 stores the blocks of zeros that ext4
   writes as holes. The zvol reserves its whole size on the pool, because ext4 on a sparse zvol gets
   write errors when the pool fills. `/var/lib/rancher` held 13 GB when the zvol was sized, and the
   cluster's PVCs request 41 GiB, which local-path does not enforce. The pool had 27 GB free, so 20G
   is what a full reservation allows. Grow the zvol later with `zfs set volsize` and `resize2fs`,
   once the pool has the space.

4. Make the ext4 filesystem on the zvol:

   **CAUTION:** `mkfs.ext4` erases the device it is given. Check the path names the new zvol.

   ```bash
   udevadm settle
   mkfs.ext4 -q -L rancher /dev/zvol/tank/cloud/rancher
   ```

5. Check the result:

   ```bash
   zfs get -H -o name,property,value encryption,keyformat,keylocation,keystatus,mountpoint -r tank/cloud
   ```

   Expect `aes-256-gcm`, `hex` and `available` on all four, the key file's URL on `tank/cloud`, and
   `legacy` on `tank/cloud` and its two filesystems.

## Switch and check

1. For a new cluster, start it before the switch, as step 14 of
   [Lose `vdb`](./lost-disk.md#lose-vdb) does. That step needs a host whose running system already
   enables `services.tank-cloud`, as a lost `vdb` leaves, because the guard and the mounts live in
   that system. The switch script cannot make the cluster: before it builds, it reads the cluster's
   atc-gateway and nixie pods over `k3s kubectl`, which reaches no API while k3s stays stopped, and
   a new cluster runs neither workload. The cluster and its workloads come before any switch,
   through that step and the rebuild it ends with.
2. Switch with `bash scripts/switch-geoffcloud.sh --allow-k3s-restart` in a planned k3s window, as
   [Workflows](./workflows.md#switch-the-host) describes. The switch restarts k3s, imp-host and the atc daemon, because their units gain the
   mount requirement, so imp-host's restart puts every awake imp to sleep. k3s starts only once the
   zvol holds a cluster's certificate authority and datastore, so it never makes a new cluster on an
   empty zvol by accident.
3. Check the mounts and the services:

   ```bash
   for path in /var/lib/tank-cloud/{host-secrets,imp-db-backups} /var/lib/rancher; do
     findmnt -n -o SOURCE,FSTYPE --mountpoint "$path"
   done
   systemctl is-active tank-cloud-key k3s imp-host atc-daemon
   ```

   Expect `tank/cloud/host-secrets zfs`, `tank/cloud/imp-db-backups zfs` and a `/dev/zd<n> ext4`
   line, then `active` four times.

   Check the binds the same way:

   ```bash
   for path in /var/lib/imp-host/secrets /var/lib/atc-daemon-secrets /root/imp-db-backups /etc/rancher; do
     findmnt -n -o SOURCE,FSTYPE --mountpoint "$path"
   done
   ```

   Expect `tank/cloud/host-secrets[/imp-host] zfs`, `tank/cloud/host-secrets[/atc-daemon] zfs`,
   `tank/cloud/imp-db-backups zfs` and `/dev/zd<n>[/etc-rancher] ext4`.

4. Make the two filesystems root-only, because they hold secrets:

   ```bash
   chmod 0700 /var/lib/tank-cloud/host-secrets /var/lib/tank-cloud/imp-db-backups
   ```

After a reboot, `zfs get -H -o value encryption,keystatus tank/cloud` prints `aes-256-gcm` and
`available`.

k3s, imp-host and the atc daemon each require their datasets' mounts. So `systemctl stop` of a mount
stops the services that require it, and `systemctl start` of the mount leaves them stopped: start
them again by name, as step 2 of
[If the key fails to load at boot](#if-the-key-fails-to-load-at-boot) does.

## If the key fails to load at boot

The unit `tank-cloud-key` fails, and its journal holds the reason, such as
`Failed to open key material file` for a missing key file. `imp-dataset-key` fails the same way for
`tank/imp`. The host stays reachable over SSH, and k3s, imp-host and the atc daemon stay stopped.
The datasets keep their data.

1. Restore the key from the 1Password item `zfs-tank-key`. The key travels on SSH's stdin, never on
   a command line, because Tailscale SSH logs each command line:

   ```bash
   op read --no-newline op://cloud/zfs-tank-key/password | ssh root@geoffcloud \
     'install -d -m 0700 /var/lib/zfs-keys && (umask 077 && cat > /var/lib/zfs-keys/tank.key) && chmod 0400 /var/lib/zfs-keys/tank.key && test "$(wc -c < /var/lib/zfs-keys/tank.key)" -eq 64 && echo ok'
   ```

   Expect `ok`. Without `ok`, the key is not 64 characters: check the item, and never write the key
   with a trailing newline.

2. Mount the datasets and start the services:

   ```bash
   ssh root@geoffcloud systemctl start tank-cloud.target k3s imp-host atc-daemon imp-host-dns-token.path
   ```

   The target requires every mount and every bind, and each mount loads the key again. imp-host's
   start runs `imp-dataset-key` again, which loads `tank/imp`'s key. The services alone would mount
   only the datasets they need, and leave `imp-db-backups` unmounted. The DNS token's path unit
   needs the imp-host secrets bind, so it stays stopped until you start it too.

3. Check as in [Switch and check](#switch-and-check).
