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

**Desk check:** every step traced against the repo at `main` `14f6e3c`, with nothing run: the pool
import and key load against the NixOS config and its checks, the reinstall against its runbook, and
the firewall group against the Onidel provider. The panel, the boot menu and the Tailscale console
stay unchecked.

**CAUTION:** A snapshot restores `vda` only. impd's database lives on `vdb`, so a snapshot from
before an imp upgrade brings back an older image beside a newer database, and impd refuses to start.
Before impd starts, either switch to a generation whose image matches the database, or restore a
database copy that matches the snapshot's image
([roll impd's database back](./restore-geoff-cloud.md#2-roll-impds-database-back)). k3s's datastore
lives on `vdb` too, so a snapshot from before a k3s upgrade brings back an older k3s binary beside a
newer datastore, which that binary may refuse or corrupt. A generation matches when its impd image
matches the database and its k3s is at least the datastore's version.

k3s and imp-host start at boot, so pick the matching generation in the systemd-boot menu, in the
noVNC console, at the restored VM's first boot. Then make it the default, so a reboot keeps it:

```bash
nix-env -p /nix/var/nix/profiles/system --switch-generation <generation>
/nix/var/nix/profiles/system/bin/switch-to-configuration boot
```

`scripts/switch-geoffcloud.sh` cannot help here, because it queries the cluster before it builds and
stops while k3s is down. A snapshot holds only the generations from before it was taken, so it often
holds no matching generation. Reinstall then, as the next bullet does.

- **From a snapshot:** `op run --env-file=.env -- bun run onidel:snapshot pre-<change>` takes one
  before a risky change. Restore it from the Onidel panel.
- **From nothing:** reinstall onto the empty disk. The pool survives with its live files, so the
  host needs only its own new tailnet key and the ZFS key:

  1. Run steps 1 to 4 of [Lose both disks](#lose-both-disks): Secure Boot off, the installer, its
     SSH server, and the `edge` group detached.
  2. Remove only the node `geoffcloud` in the Tailscale admin console, and generate one auth key for
     it: `tag:cloud`, not reusable, not ephemeral, pre-approved. Keep `imp-geoffcloud`: its identity
     is on `tank/imp`, so imp's node rejoins with it and needs no key.
  3. Run reinstall step 3 with that key in `$x/var/lib/tailscale/authkey`, and skip its
     `bun run up`. Write the key from the clipboard, as step 6 of
     [Lose both disks](#lose-both-disks) does. Stage the ZFS key as the step does, and stage none of
     the imp files, so skip the step's `chmod` of them as well: the bind from the pool's
     `host-secrets` dataset mounts imp-host's live files over `/var/lib/imp-host/secrets`, so a
     staged copy would sit hidden on `vda`.
  4. Run reinstall steps 5 to 7, with the VM's public address as the install target, as step 7 of
     [Lose both disks](#lose-both-disks) describes. Skip step 2, which needs the old host, step 4,
     because no running host holds the pool, and step 8, because nothing of imp's was staged.
  5. Give `geoffcloud` its tailnet address back, as
     [Keep the tailnet addresses](./leak-response.md#keep-the-tailnet-addresses) describes. Then
     restart each unit that `ssh root@geoffcloud systemctl --failed` lists, such as the atc daemon
     and the preview service, which failed to bind the old address.
  6. Attach the `edge` group again with an apply by hand, as
     [Apply by hand](./workflows.md#apply-by-hand) describes. Expect its baseline drift and its
     preview to show one change, the VM's firewall group. Apply with `bun run up -- --refresh`
     instead of its plain `bun run up`: the preview saves no state, so a plain apply plans no change
     and leaves the group detached.

## Lose `vdb`

**Untested.** The pool is gone, and everything on it: every imp's disk, impd's database with its
named tokens and grants, impd's own secrets, the cluster with every volume, the host's secret files
and the copies of impd's database. `vda` keeps NixOS, the key and the host's tailnet identity, so
the host boots and answers SSH, with k3s, imp-host and the atc daemon stopped. The
`geoffcloud-no-pool` NixOS check boots the host's configuration in a VM with no pool disk, and fails
unless the VM reaches that state.

**Desk check:** every step traced against the repo at `main` `14f6e3c`, with nothing run: the pool
against the NixOS checks, the secret files against their install scripts, impd's secrets and tokens
against the daemon's profiles, the credential installer and imp's token rules, and the image rebuild
against its build script. Step 12 is traced against atc's imp target and impd's token store, with
nothing run. impd's start on an empty pool stays unchecked.

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
   step 14 rebuilds the cluster.
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

7. Start a new impd with `ssh root@geoffcloud systemctl start imp-host`. imp's node joins the
   tailnet with the key from step 5, so give `imp-geoffcloud` its tailnet address back, as
   [Keep the tailnet addresses](./leak-response.md#keep-the-tailnet-addresses) describes. impd
   writes its DNS records at the node's address, so restart it with
   `ssh root@geoffcloud systemctl restart imp-host` after the edit. Then restore every imp with
   `ssh root@geoffcloud docker exec imp-host impz backup restore --all`, as
   [restore imps from restic](./restore-geoff-cloud.md#1-restore-imps-from-restic) describes.
8. Log imp's CLI on this machine in to the new impd. impd's record of the CLI's saved token was in
   its database, so each `impz` call from this machine fails with `unauthorized` until then. Wait
   until `https://imps.geoff.cloud/health` returns 200, then mint a `manage` token with no imp
   patterns in imp-host, and pass it to `impz login` on stdin:

   ```bash
   ssh root@geoffcloud docker exec imp-host impz token new operator --scope manage < /dev/null \
     | impz login https://imps.geoff.cloud
   ```

   Expect `impz token whoami` to print `operator`.

9. Add impd's secrets again, because they lived on the pool, in this order:
   - The secrets of the atc daemon's auth profiles but `op-connect`, which the Connect bullet adds
     ([the cloud daemon](../architecture/workloads/atc-gateway.md#the-cloud-daemon)), each with the
     kind, host and header of its profile in `nixos/hosts/geoffcloud/configuration.nix`, on stdin:
     `op read op://cloud/<secret>/credential | host_imp secret add <secret> --kind custom --hosts <host> --header <header> --scheme <scheme>`,
     or `--kind github` alone for the GitHub profile. Each secret's item in the 1Password vault
     `cloud` has the secret's own title: `claude-setup-token`, `github-imp-agents` and
     `linear-imp-agents`. `host_imp` is the helper at the top of [Previews](./preview.md). Step 11's
     credential installer refuses to mint the daemon's token while one of them is missing, and lists
     each missing secret.
   - The GitHub secret `gh`, through step 1 of
     [Set the service up](./preview.md#set-the-service-up). Each preview imp clones through it. The
     daemon's GitHub profile uses `github-imp-agents`, so the profile secrets leave `gh` out. impd
     refuses to mint the preview token while a secret it may grant is missing.
   - nixie's images and model secret, through
     [nixie's runbook](./nixie.md#add-nixies-images-and-model-secret-to-impd).
   - The Connect token, with the command in
     [Add the token to impd](./onepassword-connect.md#add-the-token-to-impd). Leave out `--replace`:
     impd replaces only a secret that exists.
   - The preview service's secrets and token, through steps 2 and 3 of
     [Set the service up](./preview.md#set-the-service-up), then only the `op read ... | ssh`
     commands of its steps 4 and 5, which send the stored GitHub token and webhook secret. Skip the
     switch in its step 6: the host already runs the current system, and the switch script queries
     the cluster, which step 14 rebuilds. Start the unit with
     `ssh root@geoffcloud systemctl restart preview`. The `preview-image` unit adds the preview
     imps' image at each start of imp-host, so that image needs no step.

10. Rebuild the agent image of the daemon's target. impd's images lived on the pool, and the restic
    backups hold imps, not images, so without this step the daemon cannot create an agent imp. Build
    the commit in the image's name, with the configured name read from the checkout:

    ```bash
    image=$(grep -oE '"agent-[0-9a-f]+"' nixos/hosts/geoffcloud/configuration.nix | tr -d '"')
    bun scripts/build-agent-image.ts "${image#agent-}"
    ```

    Expect the last line `<image> <digest> check passed`, with the configured name. The home-pc
    daemon's `cloud` target has its own image, which
    [Switch the `cloud` target](./agent-image.md#switch-the-cloud-target) sets. Build that commit as
    well when it differs.

11. Put the atc daemon's bearer back on the host first. The 1Password item `atc-daemon-token`
    survives, but its host copy was on the pool, and the credential installer stops when only one
    copy exists. `op read` ends the value with a newline, as the installer writes the file:

```bash
op read op://cloud/atc-daemon-token/credential | ssh root@geoffcloud 'mountpoint -q /var/lib/atc-daemon-secrets && (umask 077 && cat > /var/lib/atc-daemon-secrets/gateway-token) && chmod 0400 /var/lib/atc-daemon-secrets/gateway-token && echo ok'
```

Expect `ok`. Then mint `atc-cloud` with `bun scripts/install-atc-gateway-credentials.ts`, which
finds the two bearer copies equal and skips them. Start the daemon with
`ssh root@geoffcloud systemctl start atc-daemon`.

12. Give the home-pc daemon's `cloud` target a new impd token. Its old token was in impd's database,
    so each call the target makes to impd fails as unauthorized. Run the rest of this step on
    home-pc, as the user that runs the daemon. Read the target's impd address, token source and imp
    prefix, and the secrets the auth profiles name, from the daemon's config:

    ```bash
    jq '{target: .targets.cloud | {url, impPrefix, tokenFile, tokenEnv}, grantable: ([.authProfiles[]?.secret] | join(","))}' ~/.config/atc/config.json
    ```

    Mint the token `home-pc-cloud` in imp-host, for the imps under the target's prefix (`atc-` when
    `impPrefix` is unset), and write it straight into the file in `tokenFile`:

    ```bash
    ssh root@geoffcloud docker exec imp-host impz token new home-pc-cloud --scope manage --imps '<imp_prefix>*' --grantable '<grantable>' < /dev/null \
      | (umask 077 && cat > <token_file>)
    ```

    impd refuses the mint with `NOT_FOUND` for a secret that step 9 did not add, so add that secret
    first. When a failed attempt leaves `home-pc-cloud` in `impz token ls` in imp-host, remove it
    with `ssh root@geoffcloud docker exec imp-host impz token rm home-pc-cloud` before a rerun. Keep
    the target's token source as it is, because a change between a file and a variable changes the
    target's identity and refuses its sessions with `target_changed`. The daemon reads the file
    before each call to impd, so the new token needs no restart
    ([imp targets](https://github.com/zgeoff/atc/blob/main/docs/guides/configuration/targets.md#imp-targets)).
    A `tokenFile` under `/run/credentials` is a copy that systemd makes, so write the unit's source
    file instead and restart the daemon. A target that sets `tokenEnv` reads the variable at startup
    only, so write the token where the daemon's environment sets that variable, and restart the
    daemon with `atc daemon restart`.

    Expect `IMP_URL=<url> IMP_TOKEN="$(cat <token_file>)" impz token whoami` to print
    `home-pc-cloud`. Then spawn a session on `cloud`, as step 3 of
    [Switch the `cloud` target](./agent-image.md#switch-the-cloud-target) does.

13. Mint nixie's token into its sops file, through
    [Mint nixie's impd token](./nixie.md#mint-nixies-impd-token), and land the file through a PR.
14. Start a new cluster on the empty zvol. k3s refuses to start until the zvol holds a cluster's
    certificate authority and datastore, so lift that guard for the first start alone:

    ```bash
    ssh root@geoffcloud 'install -d /run/systemd/system/k3s.service.d && printf "[Unit]\nAssertPathExists=\n" > /run/systemd/system/k3s.service.d/first-start.conf && systemctl daemon-reload && systemctl start k3s && rm /run/systemd/system/k3s.service.d/first-start.conf && systemctl daemon-reload && echo ok'
    ```

    Expect `ok`. Then store the new kubeconfig with `bash scripts/connect-k3s.sh`, and rebuild the
    workloads through [Rebuild the cluster](./restore-geoff-cloud.md#5-rebuild-the-cluster).

15. Restore the gateway's state through
    [the gateway's runbook](./atc-gateway-backup-restore.md#restore), and nixie's through
    [Restore from a backup](./nixie.md#restore-from-a-backup).
16. Check as [After any restore](./restore-geoff-cloud.md#after-any-restore) lists.

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

**Desk check:** every step traced against the repo at `main` `14f6e3c`, with nothing run: the
installer against the host's network config and the Onidel API, the staging against the reinstall
runbook. The `geoffcloud-no-pool` NixOS check covers the boot without a pool.

1. Turn Secure Boot off for the VM in the Onidel panel, as reinstall step 1 does.
2. Boot the VM from a NixOS minimal installer ISO, through `POST /isos` and the panel, as
   [If kexec still fails](./reinstall-geoffcloud.md#if-kexec-still-fails) describes.
3. In the noVNC console, where the installer logs in as `nixos`, give the installer the VM's static
   address, because Onidel's network has no DHCP. `ip -br link` names the interface. Then give root
   your SSH key and start the installer's SSH server, which it leaves stopped:

   ```bash
   sudo ip link set <interface> up
   sudo ip addr add 104.250.100.18/24 dev <interface>
   sudo ip route add default via 104.250.100.1
   echo 'nameserver 1.1.1.1' | sudo tee /etc/resolv.conf
   curl -fsSL https://github.com/<github_user>.keys | sudo install -D -m 600 /dev/stdin /root/.ssh/authorized_keys
   sudo systemctl start sshd
   ```

   The address, gateway and name server are the ones the host's NixOS config sets. On your own
   machine, drop the old host's key with `ssh-keygen -R 104.250.100.18`, because the installer
   answers with a new one.

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
   step 2, which needs the old host, and step 4, because no pool remains. Detach the ISO in the
   Onidel panel once `nixos-anywhere` finishes, and reboot the VM through the panel if it comes back
   up in the installer. Before reinstall step 7, drop the old key with `ssh-keygen -R geoffcloud`.
   The host boots and joins the tailnet, with k3s, imp-host and the atc daemon stopped, so step 7's
   `zpool status`, `keystatus`, `k3s kubectl` and `impz` checks fail until the pool exists. Then
   give `geoffcloud` its tailnet address back, as
   [Keep the tailnet addresses](./leak-response.md#keep-the-tailnet-addresses) describes. No step
   here runs the switch script, which needs a running cluster.
8. Run steps 1 to 4 of [Lose `vdb`](#lose-vdb).
9. Delete the staged imp files from `vda` with the first block of reinstall step 8. The bind of the
   new, empty dataset shadows them, so the block takes its first branch, which deletes them through
   a bind of `/` and leaves the pool alone.
10. Continue from step 6 of [Lose `vdb`](#lose-vdb), and paste the `tag:imp` key from step 5 here.
