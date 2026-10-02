# Reinstall geoffcloud as NixOS

This runbook replaces Ubuntu on `geoffcloud` with the flake in `nixos/`. It wipes `vda` only. `vdb`
holds imp's ZFS pool, and NixOS imports it.

## Before you start

- The imp session agrees on the time. imp's node and microVMs go down.
- imp's bootstrap has created the pool `tank` on `vdb`. NixOS imports it through
  `boot.zfs.extraPools`.
- A Tailscale auth key for `tag:cloud` exists: the `hostAuthKey` stack output (Pulumi `TailnetKey`).

**CAUTION:** The reinstall erases the root disk. Take an Onidel snapshot first, through the API or
the panel, so that you can restore the Ubuntu host.

## Steps

1. Turn off Secure Boot for the VM in the Onidel panel, then reboot the VM through the API. With
   Secure Boot on, kernel lockdown blocks the kexec that `nixos-anywhere` uses.
2. Check from the host: `mokutil --sb-state` prints `SecureBoot disabled`.
3. Stage the host's Tailscale key outside the repo:

   ```sh
   mkdir -p /tmp/geoffcloud-extra/var/lib/tailscale
   (cd infra && op run --env-file=../.env -- pulumi stack output --stack prod --show-secrets hostAuthKey) \
     > /tmp/geoffcloud-extra/var/lib/tailscale/authkey
   chmod 600 /tmp/geoffcloud-extra/var/lib/tailscale/authkey
   ```

4. Install. `nixos-anywhere` runs from any machine with Nix or Docker:

   ```sh
   nix run github:nix-community/nixos-anywhere -- \
     --flake ./nixos#geoffcloud \
     --extra-files /tmp/geoffcloud-extra \
     root@104.250.100.18
   ```

5. Remove the staged key: `rm -rf /tmp/geoffcloud-extra`.
6. Check the host over the tailnet: `ssh root@geoffcloud`, then `zpool status`,
   `k3s kubectl get nodes`, and `tailscale status`.
7. Remove the stale Ubuntu-era Tailscale nodes in the admin console.

## If kexec still fails

Upload a NixOS installer ISO through the Onidel API (`POST /isos`), attach it, and boot the VM from
it over noVNC. Then run `nixos-anywhere` against the live installer, as in step 4.

## After the reinstall

- Rotate the Onidel API key.
- The old root password is gone with Ubuntu; root login is key-only.
