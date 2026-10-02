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
3. Run `bun run up -- --yes` first: the host keys expire after 7 days, and an apply mints fresh
   ones. Then stage both tailnet keys outside the repo. The host's own node uses `hostAuthKey`
   (tag:cloud). imp's node uses `impHostAuthKey` (tag:imp, not ephemeral), at the path that
   `services.imp.tailscaleAuthKeyFile` expects:

   ```sh
   x=/tmp/geoffcloud-extra
   mkdir -p $x/var/lib/tailscale $x/var/lib/imp-host/secrets
   (cd infra && op run --env-file=../.env -- pulumi stack output --stack prod --show-secrets hostAuthKey) \
     > $x/var/lib/tailscale/authkey
   (cd infra && op run --env-file=../.env -- pulumi stack output --stack prod --show-secrets impHostAuthKey) \
     > $x/var/lib/imp-host/secrets/tailscale-authkey
   chmod 600 $x/var/lib/tailscale/authkey
   chmod 400 $x/var/lib/imp-host/secrets/tailscale-authkey
   ```

   imp's node normally restarts from its saved state in `tank/imp`. A missing or used key only
   warns.

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
