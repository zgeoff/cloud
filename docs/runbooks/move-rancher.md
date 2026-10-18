# Move k3s's data onto tank/cloud

**Done:** this move ran on geoffcloud on 2026-10-18 (GEO-636, built in #367), and this runbook
records the steps that ran. #405 removed its script, `scripts/host/move-rancher.sh`, and the move's
steps from the `tank-cloud-rancher` check. Git history holds both.

k3s keeps its datastore, with every Kubernetes Secret, the agent and kubelet keys and every cluster
volume, in `/var/lib/rancher`, and the admin kubeconfig and the node password in `/etc/rancher`. On
`vda` both sit in every Onidel snapshot in the clear. This runbook moves them onto the zvol
`tank/cloud/rancher` of [tank/cloud](./tank-cloud.md), and keeps both paths: the host mounts the
zvol's ext4 at `/var/lib/rancher` and bind-mounts its directory `etc-rancher` at `/etc/rancher`.
`/var/lib/kubelet` stays on `vda`.

The sequence is a switch, a copy, a check and a removal. The switch comes first, because
`switch-geoffcloud.sh` reads nixie's pods through k3s before it activates. After the switch, the
zvol is mounted at `/var/lib/rancher` without k3s's data directory `k3s`, and k3s's unit asserts
that directory, so k3s fails to start instead of making a new cluster with a new CA on the empty
zvol. The host script `scripts/host/move-rancher.sh` does the copy and the removal. The cluster is
down from the switch to the end of the copy, about 10 to 20 minutes: the tunnel, Grafana, the atc
gateway and nixie.

The NixOS check `tank-cloud-rancher` rehearsed every step in a VM: [Rehearse it](#rehearse-it) gives
the run.

## Before you start

Run each command on geoffcloud as root, over `ssh root@geoffcloud`, unless it says otherwise.

1. Check the zvol, its reservation and its mount:

   ```bash
   zfs get -Hp -o property,value volsize,refreservation,keystatus tank/cloud/rancher
   findmnt -n -o SOURCE,FSTYPE --mountpoint /var/lib/tank-cloud/rancher
   ls -A /var/lib/tank-cloud/rancher
   ```

   Expect a `refreservation` at least as large as the `volsize`, `available`, a `/dev/zd<n> ext4`
   line, and `lost+found` alone. A zvol made with `-s` is sparse: ext4 on it gets write errors when
   the pool fills. Reserve it with `zfs set refreservation=auto tank/cloud/rancher`, which fails
   when the pool lacks the space.

2. When the reservation fails, recreate the zvol at a size the pool can reserve, such as `20G`:

   **CAUTION:** `zfs destroy` deletes the zvol and everything on it. Check that step 1 listed
   `lost+found` alone.

   ```bash
   systemctl stop /var/lib/tank-cloud/rancher
   zfs destroy tank/cloud/rancher
   zfs create -V 20G tank/cloud/rancher
   udevadm settle
   mkfs.ext4 -q -L rancher /dev/zvol/tank/cloud/rancher
   systemctl start /var/lib/tank-cloud/rancher
   systemctl start k3s
   ```

   k3s requires the zvol's mount, so the mount's stop stops k3s and the cluster's API, and the
   mount's start leaves k3s stopped. The pods keep running on `vda` until k3s starts again. Check
   again as in step 1.

3. Check the space the copy needs against the zvol's free space:

   ```bash
   du -sxh /var/lib/rancher /etc/rancher
   df -h /var/lib/tank-cloud/rancher
   ```

   The copy refuses to start when the trees do not fit.

4. From this machine, take a nixie backup and a root disk snapshot, so the cluster has a recovery
   point from before the move ([nixie backup](./nixie-backup.md),
   [Restore geoff.cloud](./restore-geoff-cloud.md#4-recover-the-root-disk)).

## Switch

1. The owner runs the switch from a clean checkout of `main`:

   ```bash
   bash scripts/switch-geoffcloud.sh
   ```

   Expect the activation to start `k3s.service` with no failed unit, and the script to print
   `== root@geoffcloud runs <path>`. k3s fails its assertion, because the zvol holds no cluster CA
   or datastore yet, and the journal of `k3s.service` holds `Assertion failed for k3s service.`

2. Stop the script with Ctrl-C once it prints `== root@geoffcloud runs <path>` and the list of
   failed units. The script's nixie readiness check follows, and it runs `k3s kubectl` on the host.
   Any k3s command unpacks k3s's binaries into `/var/lib/rancher/k3s`, and a `k3s` directory that
   appears during the copy makes the copy refuse to start k3s. Run no k3s command on the host until
   the copy ends. The host keeps the new generation.

3. Check that k3s stayed stopped and that the zvol is empty:

   ```bash
   systemctl is-active k3s
   findmnt -n -o SOURCE,FSTYPE --mountpoint /var/lib/rancher
   ls -A /var/lib/rancher
   ```

   Expect `inactive`, a `/dev/zd<n> ext4` line, and `etc-rancher` and `lost+found`, plus `k3s` when
   a k3s command ran. systemd made the empty `etc-rancher` for the bind. k3s's pods still run on
   `vda`, because the unit stops only k3s itself.

## Copy

1. From this machine, run the copy with the script on SSH's stdin:

   ```bash
   ssh root@geoffcloud bash -s -- copy < scripts/host/move-rancher.sh
   ```

   Expect these lines, then the command to return once k3s is up:

   ```text
   stopped k3s: killed <n> processes
   unmounted <n> container mounts
   copied /var/lib/rancher and /etc/rancher: <bytes> bytes
   match /var/lib/rancher: <n> entries, <n> xattrs
   match /etc/rancher: <n> entries, <n> xattrs
   started k3s on tank/cloud/rancher
   ```

   The script kills k3s's containerd, shims and containers, which outlive the unit, so nothing
   writes to the old trees during the copy. It never runs `k3s-killall.sh`, which also clears
   Tailscale's advertised routes and rewrites iptables. It refuses, and copies nothing, when either
   path is not the zvol's mount, when the zvol is sparse, or when `/var/lib/rancher/k3s` on it holds
   more than the binaries a k3s command unpacked. The copy of `/var/lib/rancher` waits in a staging
   directory until both trees match, and `k3s` moves into place last. A `MISMATCH` stops the copy
   before k3s starts; read the listed entries, then run the copy again. When a k3s command made
   `/var/lib/rancher/k3s` during the copy, the copy stops before k3s starts; stop that command, then
   run the copy again. A run that stopped part-way clears what it left on the zvol before it copies,
   and prints `cleared <n> entries an earlier copy left on the zvol`.

   The script reads the old trees through a private bind of `/` under `/run/move-rancher.<random>`,
   and removes the bind before k3s starts. When the script prints that the bind is still mounted,
   remove it as in [Remove a bind of / that the copy left](#remove-a-bind-of--that-the-copy-left).

2. From this machine, check nixie as the switch would have, since the switch stopped before its own
   check:

   ```bash
   bash scripts/check-nixie-ready.sh root@geoffcloud
   ```

   Expect every part ready.

## Check

1. Check the mounts:

   ```bash
   findmnt -n -o SOURCE,FSTYPE --mountpoint /var/lib/rancher
   findmnt -n -o SOURCE,FSTYPE --mountpoint /etc/rancher
   ```

   Expect `/dev/zd<n> ext4`, then `/dev/zd<n>[/etc-rancher] ext4`.

2. Check that the cluster CA is the one from before the move, by comparing its checksum with the
   copy on `vda`:

   ```bash
   mkdir -p /mnt/root-disk && mount --bind / /mnt/root-disk
   sha256sum /var/lib/rancher/k3s/server/tls/server-ca.crt /mnt/root-disk/var/lib/rancher/k3s/server/tls/server-ca.crt
   umount /mnt/root-disk
   ```

   Expect the same checksum twice.

3. Check the workloads: `k3s kubectl get pods -A` shows every pod `Running`, the gateway, nixie,
   Grafana and the tunnel answer, and both PVCs hold their data.

4. From a clean `main`, check that Pulumi sees no change:

   ```bash
   bun run preview -- --refresh
   ```

   Expect 0 changes.

## Remove the old copy

**CAUTION:** This deletes k3s's old data from `vda`. Run it only after the checks above pass. Past
this point the zvol holds the only copy of the datastore, apart from the nixie backup and the
snapshots.

1. Run the removal:

   ```bash
   ssh root@geoffcloud bash -s -- remove-old < scripts/host/move-rancher.sh
   ```

   Expect `removed /var/lib/rancher: <n> entries`, `removed /etc/rancher: <n> entries` and
   `removed /var/lib/tank-cloud/rancher`. The script refuses, and deletes nothing, unless the zvol
   is mounted at `/var/lib/rancher` and its `etc-rancher` at `/etc/rancher`, and the zvol holds the
   cluster CA that `vda` holds. It reads the old directories through a bind mount of `/` that it
   removes when it exits.

The old blocks stay on `vda` until something overwrites them, and the snapshots from before the move
still hold the data.

## Remove a bind of / that the copy left

A bind of `/` that the copy could not unmount holds copies of the pod mounts made while it existed,
such as their volumes. With `/`'s shared propagation, an unmount inside the bind passes to the live
mount it copies. Make the bind's whole tree private first, so the unmount touches only the bind.

**CAUTION:** Never run `umount -l` on the bind before `mount --make-rprivate`. A lazy unmount of a
shared bind detaches the live pod mounts it copies.

1. List the binds:

   ```bash
   findmnt -rn -o TARGET | grep '^/run/move-rancher'
   ```

2. Remove each bind the list starts with, here `/run/move-rancher.abc123`:

   ```bash
   mount --make-rprivate /run/move-rancher.abc123
   umount -R /run/move-rancher.abc123
   rmdir /run/move-rancher.abc123
   ```

3. Run step 1 again, and expect no line. `k3s kubectl get pods -A` still shows every pod `Running`.

## Roll back

Before the removal, the old trees are still on `vda`, as they were when the copy stopped k3s. Every
change the cluster made on the zvol since the copy is lost unless you copy the zvol's trees back
over the old ones with `cp -a` between the two steps below.

1. From this machine, stop k3s and its containers:

   ```bash
   ssh root@geoffcloud bash -s -- stop < scripts/host/move-rancher.sh
   ```

   Expect `stopped k3s: killed <n> processes` and `unmounted <n> container mounts`. k3s's containers
   outlive the unit, and their mounts keep the zvol's mounts busy, so the rollback could not unmount
   them without this step.

2. Roll the host back one generation. The old generation mounts the zvol at
   `/var/lib/tank-cloud/rancher` again and starts k3s on `vda`:

   ```bash
   ssh root@geoffcloud nixos-rebuild switch --rollback
   ```

## Rehearse it

The rehearsal ran as the NixOS check `tank-cloud-rancher` until #405, which kept only the check's
steps on the layout after the move: k3s's guard and the reboot.

The check starts a real k3s server with geoffcloud's package and flags on the root disk, with a pod
that writes into a volume directory, and recreates the zvol as in
[Before you start](#before-you-start). It switches to the config with the zvol, checks that k3s
fails its assertion on the empty zvol, on the binaries a k3s command unpacks there, and on empty
server directories, and runs the copy while k3s commands run, which the copy refuses before k3s
starts. It runs the copy again, and checks that the cluster CA, the node password, the admin
kubeconfig, a Secret, and the volume's hard link, xattr, ACL and owner survive. It then clears a
bind of `/` that holds pod mounts, runs the removal and the rollback's stop step, checks that the
zvol's mounts then unmount, and reboots with the pool's import held back past a device's default
wait, so k3s starts on the zvol only after the import.
