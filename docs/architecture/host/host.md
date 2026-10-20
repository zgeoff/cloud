# The host

`geoffcloud` is an Onidel VM in Melbourne with nested KVM, and NixOS configures the whole of it from
one flake in `nixos/`. The flake pins every input, imp's host module among them, so a commit of this
repo fixes the exact system the host runs, and a switch moves the host from one such system to the
next. NixOS keeps each earlier system as a generation, so a switch is one step to undo.
[imp on the host](./imp.md) covers impd, its container and its pool, and
[firewalls](../network/firewalls.md) covers the host's nftables tables.

## Disks

The VM has two disks with different owners:

- **The root disk** holds NixOS, the pool's key, the host's tailnet identity, its SSH host keys and
  the atc daemon's state. disko lays it out at install, and an Onidel snapshot copies it whole
  before a risky change.
- **The second disk** holds the ZFS pool `tank`, with impd's dataset and the `tank/cloud` datasets:
  k3s's data directory, the host's secret files and the copies of impd's database. NixOS imports the
  pool and never formats the disk, so a reinstall that rebuilds the root disk leaves every imp and
  the cluster in place. The host keeps the ZFS host ID the pool was created under, so the import
  needs no force, and the import finds the disk by partition UUID, because a virtio disk has no
  serial to name it by.

ZFS encrypts every dataset on the pool that holds data, and the host loads the key from the root
disk at boot, so neither disk alone exposes the data
([protection at rest](../secrets.md#protection-at-rest)). The ZFS kernel module must support the
host's kernel, so a NixOS upgrade can wait on ZFS. The reinstall runs `nixos-anywhere`, whose kexec
the VM's Secure Boot blocks, so Secure Boot stays off
([the reinstall runbook](../../runbooks/reinstall-geoffcloud.md)).

## Services

- **Tailscale** joins the host to the tailnet as `tag:cloud` and serves Tailscale SSH, which
  replaces public SSH. OpenSSH runs with keys only, and the cloud firewall keeps its port off the
  internet ([the tailnet](../network/tailnet.md)).
- **k3s** runs as a single-node server with no Traefik and no ServiceLB, because cloudflared is the
  only ingress. Its NodePorts bind to the tailnet's address range only, since kube-proxy routes a
  NodePort through forwarding, which the input firewall never sees. Pods resolve names through
  public resolvers, because the host resolves through MagicDNS, which a pod cannot reach.
- **imp-host** runs impd and its microVMs in a container on the host's Docker
  ([imp on the host](./imp.md)).
- **The atc daemon** runs as a NixOS service with its own system user, sandboxed by systemd
  ([the atc gateway](../workloads/atc-gateway.md#the-cloud-daemon)).
- **The Connect relay** is a socket-activated proxy that carries imp-host's requests to 1Password
  Connect in the cluster ([1Password Connect](../workloads/onepassword-connect.md)).
- **impd's health probe** is a timer that asks impd's loopback health endpoint and writes the result
  where node-exporter reads it ([observability](../workloads/observability.md)).
- **The cgroup CPU writer** is a service that writes the CPU time of the host's slices and units
  where node-exporter reads it ([host CPU by cgroup](../workloads/observability.md#host-cpu-by-cgroup)).

## Build, then switch

A switch runs from a clean checkout of `main` that matches the remote, and it builds before it
touches the host:

1. The switch script takes a `git archive` of the checked commit, so neither an untracked file nor
   an edit made during the run reaches the build.
2. It builds the system in a `nixos/nix` container, with the snapshot mounted read-only and the Nix
   store kept in a Docker volume between runs, so the operator's machine needs no Nix. The
   snapshot's root is the flake's source, because the host config reads the constants it shares with
   infra and the scripts from `packages/topology`, beside `nixos/`. A failed build stops the script,
   and the host sees nothing.
3. It copies the built system's closure to the host over Tailscale SSH.
4. It asks the copied system's dry activation which units the activation would stop or restart. It
   holds the switch when k3s is one of them, because nixie can stay down for minutes after k3s
   restarts. The operator lets that restart through only in a planned k3s window.
5. It points the host's system profile at the built system first, so a reboot after a failed
   activation still boots the new system, and then activates it in a transient systemd unit, so a
   dropped SSH session cannot stop the activation halfway.
6. It fails unless the host runs exactly the built system, and prints any failed unit.

The flake is evaluated once, by the build, so the host activates the exact store path that was built
and checked. Every Nix command runs from a snapshot of the commit rather than from the working tree,
which is why a switch by hand after a failed build, or a second evaluation to switch, would break
the link between the commit and the running system.
[The switch runbook](../../runbooks/workflows.md#switch-the-host) gives the commands.

## Checks

The flake holds NixOS checks for its own modules and for the impd database restore. The restore
checks boot a VM that stands in for the host and rehearse the restore script against a stand-in
impd, so the script's failure paths run before it ever runs on the real host. They need KVM.

The checks gate the host switch rather than the merge, because no merge changes the host: only the
switch script does, and an operator runs it by hand. CI builds the checks on `main` every night and
on a dispatch, never on a pull request, so an automatic bump merges without them. The switch script
refuses a commit unless a green scheduled or dispatched run on `main` covers it: the run checked
that commit, or an ancestor with no input of the checks changed since. A nightly run skips the build
when an earlier green run covers the commit, so a quiet night costs no VM boot.
[The switch runbook](../../runbooks/workflows.md#check-the-host-before-a-switch) gives the commands.
