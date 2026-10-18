# Recover a lost disk

geoffcloud has two disks. `vda` holds NixOS, the pool's key and the host's tailnet identity. `vdb`
holds the ZFS pool `tank`, with every encrypted dataset: impd's state, k3s's data directory, the
host's secret files and the copies of impd's database
([protection at rest](../architecture/secrets.md#protection-at-rest)). Pick the section for the disk
you lost. A recovery on the live host is a consequential operation: get approval for it first.

| Lost       | What survives                                    | Section                             |
| ---------- | ------------------------------------------------ | ----------------------------------- |
| `vda`      | everything on the pool                           | [Lose `vda`](#lose-vda)             |
| `vdb`      | NixOS, the key and the host's tailnet identity   | [Lose `vdb`](#lose-vdb)             |
| both disks | 1Password, Pulumi's state and the restic backups | [Lose both disks](#lose-both-disks) |

## Lose `vda`

**Untested.** No snapshot restore or reinstall has been rehearsed since geoffcloud went live. A
snapshot of the 240 GB root disk needs a VM with a disk at least that large, which an hourly Onidel
VM cannot have ([the restore drill](./restore-drill.md#restore-a-root-disk-snapshot)).

**CAUTION:** A snapshot restores `vda` only. impd's database lives on `vdb`, so a snapshot from
before an imp upgrade brings back an older image beside a newer database, and impd refuses to start.
Before impd starts, either switch to a generation whose image matches the database, or restore a
database copy that matches the snapshot's image
([roll impd's database back](./restore-geoff-cloud.md#2-roll-impds-database-back)). k3s's datastore
lives on `vdb` too, so a snapshot from before a k3s upgrade brings back an older k3s binary beside a
newer datastore, which that binary may refuse or corrupt. Before k3s starts, switch to a generation
whose k3s is at least the datastore's version.

- **From a snapshot:** `bun run onidel:snapshot` takes one before a risky change. Restore it from
  the Onidel panel.
- **From nothing:** reinstall onto the empty disk. The pool survives with its live files, so the
  host needs only its own new tailnet key and the ZFS key:

  1. Run steps 1 to 4 of [Lose both disks](#lose-both-disks): Secure Boot off, the installer, its
     SSH server, and the `edge` group detached.
  2. Remove only the node `geoffcloud` in the Tailscale admin console, and generate one auth key for
     it: `tag:cloud`, not reusable, not ephemeral, pre-approved. Keep `imp-geoffcloud`: its identity
     is on `tank/imp`, so imp's node rejoins with it and needs no key.
  3. Run reinstall step 3 with that key in `$x/var/lib/tailscale/authkey`, and skip its
     `bun run up`. Stage the ZFS key as the step does, and stage none of the imp files: the bind
     from the pool's `host-secrets` dataset mounts imp-host's live files over
     `/var/lib/imp-host/secrets`, so a staged copy would sit hidden on `vda`.
  4. Run reinstall steps 5 to 7, with the VM's public address as the install target. Skip step 2,
     which needs the old host, step 4, because no running host holds the pool, and step 8, because
     nothing of imp's was staged.
  5. Attach the `edge` group again with an apply by hand that refreshes first, as
     [Apply by hand](./workflows.md#apply-by-hand) describes. The cluster runs again, so the apply
     reaches it.

## Lose `vdb`

**Untested.** The pool is gone, and everything on it: every imp's disk, impd's database with its
named tokens and grants, impd's own secrets, the cluster with every volume, the host's secret files
and the copies of impd's database. `vda` keeps NixOS, the key and the host's tailnet identity, so
the host boots and answers SSH, with k3s, imp-host and the atc daemon stopped.

Run steps 1 to 4 on geoffcloud, as root, over `ssh root@geoffcloud`. Run the rest from a clean
checkout of `main`.

1. Have Onidel attach a new, empty disk as `vdb`, through its panel or its support, because its API
   has no volume endpoint. Create the pool on it with the properties the NixOS checks give their
   pool:

   **CAUTION:** `zpool create` erases the disk it is given. Check that `/dev/vdb` is the new, empty
   disk and not the root disk.

   ```bash
   zpool create -O mountpoint=none -O compression=lz4 -O atime=off -O xattr=sa tank /dev/vdb
   ```

2. Create `tank/imp` as its own encryption root. The key file on `vda` survives, so both roots reuse
   it. A new key works too, because no data under the old key remains: store it in `zfs-tank-key`,
   then place it as
   [If the key fails to load at boot](./tank-cloud.md#if-the-key-fails-to-load-at-boot) does.

   ```bash
   zfs create -o encryption=aes-256-gcm -o keyformat=hex \
     -o keylocation=file:///var/lib/zfs-keys/tank.key -o mountpoint=legacy tank/imp
   ```

3. Create `tank/cloud`, its children and the ext4 file system on the zvol, through steps 2 to 5 of
   [Create the datasets](./tank-cloud.md#create-the-datasets).
4. Mount every dataset, and make the two file systems root-only:

   ```bash
   systemctl start tank-cloud.target
   chmod 0700 /var/lib/tank-cloud/host-secrets /var/lib/tank-cloud/imp-db-backups
   ```

5. Remove the node `imp-geoffcloud` in the Tailscale admin console, because its state was on the
   pool. Then generate an auth key for imp's node on the console's Keys page: tag `tag:imp`, not
   reusable, not ephemeral, pre-approved. Do not mint it with `bun run up`: Pulumi's Kubernetes
   provider still points at the lost cluster, so an apply fails on the unreachable resources until
   step 11 rebuilds the cluster.
6. Install imp-host's secret files from the console and 1Password, each on SSH's stdin, then install
   the DNS token:

   ```bash
   put() { ssh root@geoffcloud "mountpoint -q /var/lib/imp-host/secrets && cd /var/lib/imp-host/secrets && (umask 077 && cat > $1) && chmod 400 $1 && echo ok"; }
   put tailscale-authkey # paste the key from step 5, then press Ctrl-D
   op read op://cloud/imp-restic/password | put backup-password
   printf '%s\n' \
     "IMP_BACKUP_REPOSITORY=s3:$(op read op://cloud/r2-backups/endpoint)/geoff-cloud-backups/imp/geoffcloud" \
     "AWS_ACCESS_KEY_ID=$(op read op://cloud/r2-backups/access-key-id)" \
     "AWS_SECRET_ACCESS_KEY=$(op read op://cloud/r2-backups/secret-access-key)" \
     "AWS_DEFAULT_REGION=auto" \
     | put imp-host.env
   bash scripts/install-imp-dns-token.sh
   ```

   Expect `ok` three times, then the script's `installed:` line. The pasted key reaches the host on
   stdin, so it stays out of the shell history and every command line.

7. Start a new impd with `ssh root@geoffcloud systemctl start imp-host`, and restore every imp with
   `impz backup restore --all`, as
   [restore imps from restic](./restore-geoff-cloud.md#1-restore-imps-from-restic) describes.
8. Add impd's secrets again, because they lived on the pool:
   - nixie's images and model secret, through
     [nixie's runbook](./nixie.md#add-nixies-images-and-model-secret-to-impd).
   - A fresh Connect token, through [Rotate](./onepassword-connect.md#rotate) in the Connect
     runbook.
   - The preview service's secrets and token, through
     [Set the service up](./preview.md#set-the-service-up).
   - The sign-in secrets that the atc daemon's profiles name
     ([the cloud daemon](../architecture/workloads/atc-gateway.md#the-cloud-daemon)), from their
     sources.
9. Put the atc daemon's bearer back on the host first. The 1Password item `atc-daemon-token`
   survives, but its host copy was on the pool, and the credential installer stops when only one
   copy exists. `op read` ends the value with a newline, as the installer writes the file:

   ```bash
   op read op://cloud/atc-daemon-token/credential | ssh root@geoffcloud 'mountpoint -q /var/lib/atc-daemon-secrets && (umask 077 && cat > /var/lib/atc-daemon-secrets/gateway-token) && chmod 0400 /var/lib/atc-daemon-secrets/gateway-token && echo ok'
   ```

   Expect `ok`. Then mint `atc-cloud` with `bun scripts/install-atc-gateway-credentials.ts`, which
   finds the two bearer copies equal and skips them. Start the daemon with
   `ssh root@geoffcloud systemctl start atc-daemon`.

10. Mint nixie's token into its sops file, through
    [Mint nixie's impd token](./nixie.md#mint-nixies-impd-token), and land the file through a PR.
11. Start a new cluster on the empty zvol. k3s refuses to start until the zvol holds a cluster's
    certificate authority and datastore, so lift that guard for the first start alone:

    ```bash
    ssh root@geoffcloud 'install -d /run/systemd/system/k3s.service.d && printf "[Unit]\nAssertPathExists=\n" > /run/systemd/system/k3s.service.d/first-start.conf && systemctl daemon-reload && systemctl start k3s && rm /run/systemd/system/k3s.service.d/first-start.conf && systemctl daemon-reload && echo ok'
    ```

    Expect `ok`. Then store the new kubeconfig with `bash scripts/connect-k3s.sh`, and rebuild the
    workloads through [Rebuild the cluster](./restore-geoff-cloud.md#5-rebuild-the-cluster).

12. Restore the gateway's state through
    [the gateway's runbook](./atc-gateway-backup-restore.md#restore), and nixie's through
    [Restore from a backup](./nixie.md#restore-from-a-backup).
13. Check as [After any restore](./restore-geoff-cloud.md#after-any-restore) lists.

The copies of impd's database, impd's named tokens and its grants do not come back. Each token
consumer gets a new token in the steps above.

## Lose both disks

**Untested.** Reinstall, then rebuild the pool. Besides the items the reinstall reads, the recovery
needs the backups' passwords and R2 keys and the Pulumi passphrase, in the 1Password items
`imp-restic`, `r2-backups`, `atc-gateway-restic`, `r2-atc-gateway-backup` and `pulumi-passphrase`.
It does not need the old key in `zfs-tank-key`, because no data under that key remains. The
reinstall stages whatever key the item holds, and the new roots use it.

The reinstall runbook starts from a running host, which no longer exists, and its `bun run up` mint
fails while Pulumi points at the lost cluster. So the recovery boots an installer first, mints both
tailnet keys in the Tailscale admin console, and runs only the reinstall steps that need no old
host.

1. Turn Secure Boot off for the VM in the Onidel panel, as reinstall step 1 does.
2. Boot the VM from a NixOS minimal installer ISO, through `POST /isos` and the panel, as
   [If kexec still fails](./reinstall-geoffcloud.md#if-kexec-still-fails) describes.
3. In the noVNC console, where the installer logs in as `nixos`, give root your SSH key and start
   the installer's SSH server, which it leaves stopped:

   ```bash
   curl -fsSL https://github.com/<github_user>.keys | sudo install -D -m 600 /dev/stdin /root/.ssh/authorized_keys
   sudo systemctl start sshd
   ```

4. Detach the `edge` firewall group from the VM in the Onidel panel, because it drops public SSH.
   The installed host keeps its public port 22 shut by itself, and the `up --refresh` of
   [Rebuild the cluster](./restore-geoff-cloud.md#5-rebuild-the-cluster) attaches the group again.
5. Remove the nodes `geoffcloud` and `imp-geoffcloud` in the Tailscale admin console. Generate two
   auth keys on its Keys page, each not reusable, not ephemeral and pre-approved: one with
   `tag:cloud` for the host, and one with `tag:imp` for imp's node.
6. Run reinstall step 3 with those two keys in place of the two `pulumi stack output` reads, and
   skip its `bun run up`. Write each key into its staged file from the clipboard, for example
   `(umask 077 && cat > $x/var/lib/tailscale/authkey)`, then paste and press Ctrl-D.
7. Run reinstall steps 5 to 7, with the VM's public address as the install target. Skip reinstall
   step 2, which needs the old host, and step 4, because no pool remains. The host boots and joins
   the tailnet, with k3s, imp-host and the atc daemon stopped.
8. Run steps 1 to 4 of [Lose `vdb`](#lose-vdb).
9. Delete the staged imp files from `vda` with the first block of reinstall step 8. The bind of the
   new, empty dataset shadows them, so the block takes its first branch, which deletes them through
   a bind of `/` and leaves the pool alone.
10. Continue from step 6 of [Lose `vdb`](#lose-vdb), and paste the `tag:imp` key from step 5 here.
