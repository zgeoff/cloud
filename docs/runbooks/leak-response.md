# Leak response

This runbook gives the response to four leaks: an Onidel snapshot, the Onidel account, a restic
backup and the disk `vdb`. Each section lists what the leak exposes and what to revoke, with the
1Password item and the command for each credential. What a leak exposes follows from the host's
layout: the data sits on `vdb` and its key on `vda`, so neither disk alone exposes the data
([protection at rest](../architecture/secrets.md#protection-at-rest)).

The response revokes what the leak hands over now, and rotates nothing else. Every credential that
ever sat in a `vda` snapshot stays valid, which is an accepted risk
([accepted risks](../architecture/secrets.md#accepted-risks)). Deleting old snapshots and cleaning
the root disk's free space are the only ways to shrink that exposure.

**CAUTION:** Each revocation changes live access to the host or a backup. State its exact effect to
the coordinating agent, and act only on its approval.

## An Onidel snapshot leaks

A snapshot copies `vda`, which holds these in plain form:

- the host's Tailscale node state, with its node key, its machine key and its Tailscale SSH host
  keys, which let the holder join the tailnet as `geoffcloud` with `tag:cloud`'s grants
- the OpenSSH host keys, which let the holder pose as the host to an SSH client
- the ZFS key, which opens nothing without a copy of `vdb`
- the atc daemon's state directory, which holds neither of the daemon's tokens

A snapshot from before the encryption holds every host secret file and the cluster's datastore in
plain form as well. No such snapshot remains, and the response for it is the account response,
because the exposure is the same.

1. Delete the snapshot through `DELETE /snapshots/<snapshot_id>` on the Onidel API, so it leaks no
   further.
2. Revoke the host's node and its host keys, as [Rejoin the tailnet](#rejoin-the-tailnet) describes.
3. Change the ZFS key, as [Change the ZFS key](#change-the-zfs-key) describes, so the leaked key
   cannot open a later copy of `vdb`. That holds only while no copy of `vdb` leaked with it.

## The Onidel account leaks

**Encryption does not stop this leak.** The account controls the running host, with the key loaded,
so it reaches every disk and every secret on the host. The response hardens the account and accepts
the rest, which is an accepted risk.

| Credential           | 1Password item  | Command                                                                               |
| -------------------- | --------------- | ------------------------------------------------------------------------------------- |
| the account's login  | none in `cloud` | change the password and enrol a second factor in the Onidel panel                     |
| the Onidel API key   | `onidel-api`    | mint a key in the panel, store it in `cloud` and `cloud-deploy`, then `bun run drift` |
| the host's node keys | none            | [Rejoin the tailnet](#rejoin-the-tailnet)                                             |

`bun run drift` reads the VM through the new key, so its success shows the key works. Delete the old
key in the panel after it. Delete every snapshot the account holds, as
[An Onidel snapshot leaks](#an-onidel-snapshot-leaks) does.

## A restic backup leaks

A restic repository holds ciphertext, and its password sits in 1Password and in a file or Secret on
the encrypted pool, never on `vda`. A leaked repository alone therefore exposes nothing. A
repository and its password together expose that system's backed-up data.

| Repository  | Password item        | R2 key item             |
| ----------- | -------------------- | ----------------------- |
| imp's       | `imp-restic`         | `r2-backups`            |
| the gateway | `atc-gateway-restic` | `r2-atc-gateway-backup` |
| nixie's     | `nixie-restic`       | `r2-nixie-backup`       |

nixie's bucket also holds hq's repository, under the password in `hq-restic`.

When an R2 key leaked the repository, roll that key in Cloudflare's R2 dashboard, store the new key
in its item, and deliver it:

- **imp's key:** rewrite `imp-host.env` with the `printf ... | put imp-host.env` lines of step 6 in
  [Lose `vdb`](./lost-disk.md#lose-vdb), then run `bash scripts/install-imp-dns-token.sh`, which
  adds the ACME email back, and `ssh root@geoffcloud systemctl restart imp-host`. The restart puts
  every awake imp to sleep.
- **The gateway's or nixie's key:** store it in the `cloud-deploy` copy too, and apply by hand, as
  [Apply by hand](./workflows.md#apply-by-hand) describes. The apply writes the key into the backup
  CronJob's Secret.

The response leaves each restic password in place. A password that sat in an old `vda` snapshot
stays valid, which is the accepted no-rotation risk. The host's Tailscale node needs no revocation,
because no backup holds its state.

## `vdb` leaks

A copy of `vdb` holds ciphertext without the key. ZFS leaves the names and properties of the
datasets readable, and encrypts their contents. The response revokes nothing, the host's Tailscale
node included, because the node's state sits on `vda`.

When the key leaked as well, through a snapshot or the account, the holder can read the copy. Answer
it as [The Onidel account leaks](#the-onidel-account-leaks) does. A new ZFS key does not protect the
leaked copy, and `zfs change-key` keeps the master key, so the old key and the copy still read a
later copy of `vdb`. That is an accepted risk.

## Rejoin the tailnet

**Untested.** The host drops its node state and its OpenSSH host keys, reboots, and joins the
tailnet again with a new auth key. The reboot puts every imp to sleep and restarts the cluster.

1. Mint a fresh `hostAuthKey`, which the Pulumi provider makes with the OAuth client in the
   1Password item `tailscale-oauth`. Use the `--replace` of `geoffcloud-host` from step 3 of
   [the reinstall runbook](./reinstall-geoffcloud.md#steps), and apply by hand, because the apply
   job holds a replace.
2. Place the key on the host, on SSH's stdin:

   ```bash
   (cd infra && op run --env-file=../.env -- pulumi stack output --stack prod --show-secrets hostAuthKey) \
     | ssh root@geoffcloud '(umask 077 && cat > /var/lib/tailscale/authkey) && echo ok'
   ```

   Expect `ok`.

3. Schedule the rejoin, which runs after you remove the old node:

   ```bash
   ssh root@geoffcloud 'systemd-run --on-active=120 --unit=tailnet-rejoin sh -c "systemctl stop tailscaled && rm -rf /var/lib/tailscale/tailscaled.state /var/lib/tailscale/ssh && rm -f /etc/ssh/ssh_host_* && systemctl reboot"'
   ```

4. Within the two minutes, remove the node `geoffcloud` in the Tailscale admin console. The removal
   revokes the leaked keys and frees the name.
5. Wait for the host to rejoin. NixOS joins the tailnet with the staged key at boot and makes new
   OpenSSH host keys when they are missing. Then drop the old host key and check:

   ```bash
   ssh-keygen -R geoffcloud
   ssh root@geoffcloud tailscale status --self
   ```

   Expect one line for `geoffcloud` with `tag:cloud`. If the host does not rejoin, reboot it through
   the Onidel API: the boot joins with the staged key.

## Change the ZFS key

**Untested.** `zfs change-key` wraps the master key under a new key on both encryption roots, and
the master key stays the same. So the change protects a later copy of `vdb` only when the old key
leaked without any copy of `vdb`. Someone who holds the old key and an earlier copy of `vdb`
recovers the master key from that copy, and the master key decrypts every later copy as well.

Only a new encryption root gets a new master key, so a leak of both needs the data moved into new
roots, such as by a `zfs send` without `--raw` into a dataset made with a new key. This runbook does
not cover that move. Until it happens, the pair reads every copy of `vdb`, which is the accepted
risk on the master key ([accepted risks](../architecture/secrets.md#accepted-risks)).

1. Make the new key on the host:

   ```bash
   ssh root@geoffcloud '(umask 077 && od -An -vtx1 -N32 /dev/urandom | tr -d " \n" > /var/lib/zfs-keys/tank.key.new) && test "$(wc -c < /var/lib/zfs-keys/tank.key.new)" -eq 64 && echo ok'
   ```

   Expect `ok`.

2. Store it in the 1Password item `zfs-tank-key` before the pool uses it, and check that the item
   matches the file:

   ```bash
   op item edit zfs-tank-key --vault cloud "password=$(ssh root@geoffcloud cat /var/lib/zfs-keys/tank.key.new)"
   op read --no-newline op://cloud/zfs-tank-key/password | ssh root@geoffcloud 'cmp - /var/lib/zfs-keys/tank.key.new && echo same'
   ```

   Expect `same`. The SSH command lines hold only paths, so the journal records no key.

3. Change the key of both roots, and put the new key at the usual path:

   ```bash
   ssh root@geoffcloud 'cd /var/lib/zfs-keys && zfs change-key -o keylocation=file:///var/lib/zfs-keys/tank.key.new tank/cloud && zfs change-key -o keylocation=file:///var/lib/zfs-keys/tank.key.new tank/imp && mv tank.key.new tank.key && chmod 0400 tank.key && zfs set keylocation=file:///var/lib/zfs-keys/tank.key tank/cloud && zfs set keylocation=file:///var/lib/zfs-keys/tank.key tank/imp && echo ok'
   ```

   Expect `ok`. Without it, run `zfs get -H -o name,value keylocation tank/cloud tank/imp`: each
   root's key location holds the file that opens it, so keep both files until both roots hold
   `tank.key`.

4. Check:
   `ssh root@geoffcloud zfs get -H -o name,property,value keylocation,keystatus tank/cloud tank/imp`
   prints `file:///var/lib/zfs-keys/tank.key` and `available` for both roots.
