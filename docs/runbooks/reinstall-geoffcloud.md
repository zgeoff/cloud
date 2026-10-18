# Reinstall geoffcloud as NixOS

This runbook replaces Ubuntu on `geoffcloud` with the flake in `nixos/`. It wipes `vda` only. `vdb`
holds imp's ZFS pool, and NixOS imports it.

## Before you start

- The imp session agrees on the time. imp's node and microVMs go down.
- imp's bootstrap has created the pool `tank` on `vdb`. NixOS imports it through imp's module
  (`services.imp.zfs.pool`).
- A Tailscale auth key for `tag:cloud` exists: the `hostAuthKey` stack output (Pulumi `TailnetKey`).

**CAUTION:** The reinstall erases the root disk. Take an Onidel snapshot first, so that you can
restore the Ubuntu host. Through the API: `POST /vm/<vm-id>/snapshot?team_id=<team>` with the body
`{"name": "...", "team_id": "<team>"}`. Wait until `GET /snapshots` shows it as `available`.

## Steps

1. Turn off Secure Boot for the VM in the Onidel panel, then reboot the VM through the API. With
   Secure Boot on, kernel lockdown blocks the kexec that `nixos-anywhere` uses.
2. Check from the host: `mokutil --sb-state` prints `SecureBoot disabled`.
3. Mint fresh host keys first. Both are single-use and keep their used or expired state
   (`recreateIfInvalid: 'never'`), so only a replace makes new ones:

   ```sh
   bun run up -- --yes \
     --replace 'urn:pulumi:prod::geoff-cloud::tailscale:index/tailnetKey:TailnetKey::geoffcloud-host' \
     --replace 'urn:pulumi:prod::geoff-cloud::tailscale:index/tailnetKey:TailnetKey::imp-geoffcloud'
   ```

   Then stage both tailnet keys outside the repo. The host's own node uses `hostAuthKey`
   (tag:cloud). imp's node uses `impHostAuthKey` (tag:imp, not ephemeral), at the path that
   `services.imp.tailscaleAuthKeyFile` expects:

   ```sh
   x=/tmp/geoffcloud-extra
   mkdir -p $x/var/lib/tailscale $x/var/lib/imp-host/secrets
   (cd infra && op run --env-file=../.env -- pulumi stack output --stack prod --show-secrets hostAuthKey) \
     > $x/var/lib/tailscale/authkey
   (cd infra && op run --env-file=../.env -- pulumi stack output --stack prod --show-secrets impHostAuthKey) \
     > $x/var/lib/imp-host/secrets/tailscale-authkey
   op read op://cloud/imp-restic/password > $x/var/lib/imp-host/secrets/backup-password
   printf '%s\n' \
     "IMP_BACKUP_REPOSITORY=s3:$(op read op://cloud/r2-backups/endpoint)/geoff-cloud-backups/imp/geoffcloud" \
     "AWS_ACCESS_KEY_ID=$(op read op://cloud/r2-backups/access-key-id)" \
     "AWS_SECRET_ACCESS_KEY=$(op read op://cloud/r2-backups/secret-access-key)" \
     "AWS_DEFAULT_REGION=auto" \
     > $x/var/lib/imp-host/secrets/imp-host.env
   chmod 600 $x/var/lib/tailscale/authkey
   chmod 400 $x/var/lib/imp-host/secrets/*
   ```

   The three imp files map to `services.imp.tailscaleAuthKeyFile`, `services.imp.environmentFile` (a
   Docker env file: `KEY=value`, no quotes) and `services.imp.backupPasswordFile`.

   imp's node normally restarts from its saved state in `tank/imp`. A missing or used key only
   warns.

   The pool `tank` keeps `tank/cloud`, which holds the live copies of the imp files and of the atc
   daemon's tokens ([tank/cloud](./tank-cloud.md)). The install puts the staged imp files on `vda`
   in the clear, and a bind mount from `tank/cloud` shadows them without removing them. Step 8 moves
   them into `tank/cloud` or deletes them, and the reinstall is not complete before it.

   Stage the key of the encryption root `tank/cloud` too. `--no-newline` keeps the file at exactly
   the key's 64 hex characters, so the length check catches a wrong item before the install:

   ```sh
   install -d -m 0700 $x/var/lib/zfs-keys
   (umask 077 && op read --no-newline op://cloud/zfs-tank-key/password > $x/var/lib/zfs-keys/tank.key)
   chmod 400 $x/var/lib/zfs-keys/tank.key
   test "$(wc -c < $x/var/lib/zfs-keys/tank.key)" -eq 64 && echo ok
   ```

   The key directory and file never exist with a mode another account can read. A `umask` around the
   whole staging block would not do: `--extra-files` copies each directory's mode, so `/var` and
   `/var/lib` would land as `0700` on the host.

   Expect `ok`. Without it, check the item and stage the key again before you go on.

   Without the key, the host boots and joins the tailnet, but k3s, imp-host and the atc daemon stay
   stopped ([tank/cloud](./tank-cloud.md#if-the-key-fails-to-load-at-boot)).

4. Stop imp on the old host, and export its pool, so that NixOS imports `tank` cleanly:

   ```sh
   ssh root@104.250.100.18 'docker stop imp-host && zpool export tank'
   ```

   If the export reports the pool as busy, find the process that holds it, stop it, and export
   again. Do not skip the export.

5. Install. `nixos-anywhere` runs from any machine with Nix:

   ```sh
   nix run github:nix-community/nixos-anywhere -- \
     --flake '.?dir=nixos#geoffcloud' \
     --extra-files /tmp/geoffcloud-extra \
     root@104.250.100.18
   ```

   **NOTE:** Without local Nix, run it in the `nixos/nix` image. Mount the repo, the staged
   directory and a copy of the SSH key and `known_hosts` that root owns (SSH refuses a mounted
   `~/.ssh` with another owner). Enable `nix-command flakes`, and add `safe.directory = *` to root's
   git config, because the mounted repo has another owner.

6. Remove the staged key: `rm -rf /tmp/geoffcloud-extra`.
7. Check the host over the tailnet: `ssh root@geoffcloud`, then `zpool status`,
   `zfs get -H -o value keystatus tank/cloud` (expect `available`), `k3s kubectl get nodes`,
   `tailscale status` and `impz status`.

   **NOTE:** The installed host keeps port 22 shut on its public interface, whatever the edge
   allows, so the tailnet is its only SSH path. If the host does not join the tailnet, reach it
   through the Onidel noVNC console.

8. Clear the staged imp files off `vda`, which Onidel snapshots. On the host, check the bind:

   ```sh
   findmnt -n -o SOURCE,FSTYPE --mountpoint /var/lib/imp-host/secrets
   ```

   With `tank/cloud/host-secrets[/imp-host] zfs`, the pool held the live copies and the bind shadows
   the staged ones: delete them through a bind of `/` that shows the root disk, and keep what the
   pool holds:

   ```sh
   d=$(mktemp -d /run/staged.XXXXXX) && mount --bind / "$d" &&
     rm -f "$d"/var/lib/imp-host/secrets/* &&
     ls -A "$d"/var/lib/imp-host/secrets &&   # expect no output
     umount "$d" && rmdir "$d" && echo removed
   ```

   Expect `removed`. The `&&` chain stops before the `rm` when `mktemp` or the bind fails, since an
   empty `$d` would make the `rm` delete the live files on the pool.

   With no output from `findmnt`, the pool lacks `host-secrets/imp-host` and the bind failed, so
   imp-host stays stopped. Copy the staged files into the encrypted dataset, mount the binds, and
   delete the staged copies the same way:

   **CAUTION:** The staged files are the host's only local copies. Delete them only after the copy
   succeeds and matches, as the `&&` chain below does: a failed `cp -a`, such as on a full pool,
   then stops the block and keeps them. The chain starts with `mountpoint -q`, so it never copies
   the files onto the empty mount point on the root disk while the dataset is not mounted.

   ```sh
   mountpoint -q /var/lib/tank-cloud/host-secrets &&
     install -d -m 0700 /var/lib/tank-cloud/host-secrets/imp-host /var/lib/tank-cloud/host-secrets/atc-daemon &&
     cp -a /var/lib/imp-host/secrets/. /var/lib/tank-cloud/host-secrets/imp-host/ &&
     diff -r /var/lib/imp-host/secrets /var/lib/tank-cloud/host-secrets/imp-host > /dev/null &&
     systemctl start tank-cloud.target imp-host &&
     findmnt -n -o SOURCE,FSTYPE --mountpoint /var/lib/imp-host/secrets &&
     d=$(mktemp -d /run/staged.XXXXXX) && mount --bind / "$d" &&
     rm -f "$d"/var/lib/imp-host/secrets/* &&
     umount "$d" && rmdir "$d" && echo removed
   ```

   Expect `tank/cloud/host-secrets[/imp-host] zfs`, then `removed`. Without `removed`, the block
   stopped at the failed step, and the staged copies stay on the root disk. Run
   `bash scripts/install-imp-dns-token.sh` from this machine to restore the DNS token, which the
   reinstall does not stage. The script refuses to write while the bind is not mounted.

9. Remove the stale Ubuntu-era Tailscale nodes in the admin console.

## Connect Pulumi to k3s

The stack config `cluster` says whether Pulumi manages k3s. With `none`, the program leaves every
k3s workload out. With `managed` (the `prod` setting), a run without `K3S_KUBECONFIG` fails before
any resource registers. Keep `cluster: none` until step 1 has stored the kubeconfig, then set
`pulumi config set cluster managed`.

1. Run `bash scripts/connect-k3s.sh`. It stores the kubeconfig as the document
   `op://cloud/k3s-kubeconfig/kubeconfig.yaml`, with the server set to `https://geoffcloud:6443`,
   and adds the reference to `.env`.
2. Run `bun run up -- --yes`. It deploys cloudflared, Prometheus, Grafana, Loki and Alloy.
3. Grafana is at `http://geoffcloud:30300` on the tailnet. The admin password is the
   `grafanaAdminPassword` stack output.

## Close public SSH

Do this only after `ssh root@geoffcloud` works over the tailnet.

**CAUTION:** Onidel's firewall semantics are not tested: if it drops reply traffic, the host can
lose its public network. Take an Onidel snapshot first, and keep the noVNC console at hand.

1. `cd infra && op run --env-file=../.env -- pulumi config set --stack prod hostOnTailnet true`
2. `bun run up -- --yes`. It attaches the `edge` firewall to the VM and removes its SSH rules.
3. Check: `ssh root@geoffcloud` still works, `ssh root@104.250.100.18` times out, and
   `tailscale ping geoffcloud` answers.

## If kexec still fails

Upload a NixOS installer ISO through the Onidel API (`POST /isos`), attach it, and boot the VM from
it over noVNC. Then run `nixos-anywhere` against the live installer, as in step 4.

## After the reinstall

- Rotate the Onidel API key.
- The old root password is gone with Ubuntu; root login is key-only.
