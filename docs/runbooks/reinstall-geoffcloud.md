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
3. Run `bun run up -- --yes` first: the host key expires after 7 days, and an apply mints a fresh
   one. Then stage the host's Tailscale key outside the repo:

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

## Connect Pulumi to k3s

The Pulumi program skips every k3s workload until `K3S_KUBECONFIG` is set.

1. Store the kubeconfig in 1Password, with the server set to the host's tailnet name:

   ```sh
   ssh root@geoffcloud cat /etc/rancher/k3s/k3s.yaml \
     | sed 's#https://127.0.0.1:6443#https://geoffcloud:6443#' \
     | op document create --vault cloud --title k3s-kubeconfig --file-name kubeconfig.yaml -
   ```

2. Add `K3S_KUBECONFIG=op://cloud/k3s-kubeconfig/kubeconfig.yaml` to `.env`. A document resolves by
   its file name. Do this only after the item exists: `op run` fails on a reference it cannot
   resolve.
3. `bun run up -- --yes` deploys cloudflared, Prometheus, Grafana, Loki and Alloy.
4. Grafana is at `http://geoffcloud:30300` on the tailnet. The admin password is the
   `grafanaAdminPassword` stack output.

## If kexec still fails

Upload a NixOS installer ISO through the Onidel API (`POST /isos`), attach it, and boot the VM from
it over noVNC. Then run `nixos-anywhere` against the live installer, as in step 4.

## After the reinstall

- Rotate the Onidel API key.
- The old root password is gone with Ubuntu; root login is key-only.
