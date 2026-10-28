# Switch geoffcloud from imp 5 on Docker to imp 6 on Podman

imp 6.0.0 runs imp-host under rootful Podman instead of Docker, and its NixOS module no longer
enables Docker. The host switch that brings imp 6 to geoffcloud therefore stops the Docker
container, removes Docker and `imp-docker-proxy` from the host, and starts imp-host under Podman on
Podman's default network, whose bridge `podman0` replaces `docker0` for the Connect relay and the
preview model route listener. imp-host's CPU weight moves with it, from Docker's `imp.slice` to
`machine.slice`, where rootful Podman puts each container. impd's data on `tank/imp` stays as it is,
and imp 6.0.1 adds no database migration to 5.0.0, so a rollback keeps the database. This runbook
moves the host once, from imp 5.0.0 to imp 6.0.1, and back if the move fails.

## Before the switch

The pull request that bumps imp to 6.0.1 changes two things outside the host: the egress-deny
NetworkPolicy refuses pods Podman's subnet instead of Docker's, and nixie's imp config lists the
host's address on `podman0`. `Deploy prod` applies both once the pull request merges. Until the
switch, inet cloud_host on the host still drops pod traffic to Docker's subnet, so no pod reaches
imp-host on `docker0` in between.

Check each of these before you start:

- A nixie release that accepts impd 6 runs in the cluster. nixie 0.49.1 accepts impd 2 to 5 only,
  and the switch script refuses the switch while such a nixie pod runs
  ([Switch the host](./workflows.md#switch-the-host)). Deploy the first nixie release with impd 6 in
  its imp adapter first, as [the nixie runbook](./nixie.md) describes.
- A green `NixOS checks` run on `main` covers the merge commit. Dispatch one with
  `bun run ops:nixos-checks` when the nightly run has not.
- No `Deploy prod` run is in progress, and the last one on the merge commit passed.
- The owner approved the window. Every awake imp sleeps for the switch, and each wakes on its next
  request.

## Switch

1. Copy impd's database on the old host:

   ```bash
   bash scripts/copy-impd-db.sh imp-5.0.0-pre-6.0.1
   ```

   Expect the `COPY-INFO` lines, with `integrity ok`, `impVersion 5.0.0` and an `image` line for
   `imp-host:5.0.0`.

2. Sleep every awake imp, one at a time, while imp-host still runs under Docker:

   ```bash
   ssh root@geoffcloud 'docker exec imp-host impz ls --json' < /dev/null \
     | jq -r '.[] | select(.state == "running") | .name' \
     | while read -r name; do ssh root@geoffcloud docker exec imp-host impz sleep "$name" < /dev/null && echo "$name asleep"; done
   ```

   Expect one `<name> asleep` line for each awake imp. If a sleep fails, stop here: the host still
   runs imp 5.0.0, and nothing has changed.

3. Switch the host from a clean checkout of `main` at the merge commit:

   ```bash
   bun run ops:switch-host
   ```

   Expect the first line `== checked by <run url>`, and exit 0 after nixie reports ready and the
   image folder check passes. The script holds a switch whose activation would restart k3s; pass
   `--allow-k3s-restart` only in a k3s window that the owner approved.

4. Check that imp-host runs under Podman and Docker is gone:

   ```bash
   ssh root@geoffcloud 'podman inspect imp-host --format "{{.Config.Image}}"; systemctl is-active docker.service imp-docker-proxy.service' < /dev/null
   ```

   Expect `ghcr.io/zgeoff/imp-host@sha256:<digest>`, with the digest that `services.imp.image` pins,
   then `inactive` twice.

5. Check impd and its imps:

   ```bash
   ssh root@geoffcloud podman exec imp-host impz info < /dev/null
   ssh root@geoffcloud podman exec imp-host impz ls < /dev/null
   ```

   Expect `version 6.0.1`, a `boot status` line, and every imp from before the switch, asleep. imp
   6.0.1 keeps imp 5.0.0's Firecracker, so each sleeping imp restores its memory when it wakes.
   `https://imps.geoff.cloud/health` returns 200 from the tailnet.

6. Wake one imp and run a command in it:

   ```bash
   ssh root@geoffcloud podman exec imp-host impz exec <imp_name> -- uname -a < /dev/null
   ```

   Expect the imp's kernel line. The exec wakes the imp first.

7. Point the broker's two upstream secrets at `podman0`, as
   [Rebind the upstream secrets](#rebind-the-upstream-secrets) describes.

8. Check the listeners on `podman0` from inside imp-host:

   ```bash
   ssh root@geoffcloud podman exec imp-host curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://10.88.0.1:18081/heartbeat < /dev/null
   ssh root@geoffcloud 'systemctl is-active preview-image.service preview.service' < /dev/null
   ```

   Expect `200` from 1Password Connect through the relay, then `active` twice. Then run the
   post-switch checks that the bump's pull request lists, a preview boot and a cloud spawn and adopt
   among them.

9. Move nothing else by hand. The switch script moves `deployed/host` once its checks pass.

## Roll back to imp 5.0.0

Roll back when imp-host does not come up under Podman, or when a post-switch check fails and no fix
can wait. The previous generation brings back Docker, `imp-docker-proxy` and imp-host's Docker unit,
and Docker still holds the 5.0.0 image, so the rollback pulls nothing.

**CAUTION:** The rollback stops imp-host, and the stop sleeps every awake imp within its stop
timeout. An imp that does not sleep in time loses its memory, not its disk. Sleep the awake imps
first, as step 2 does, with `podman` in place of `docker`.

1. Activate the previous generation:

   ```bash
   ssh root@geoffcloud nixos-rebuild switch --rollback
   ```

   Expect exit 0.

2. Check that imp-host runs under Docker on the 5.0.0 image:

   ```bash
   ssh root@geoffcloud 'docker inspect imp-host --format "{{.Config.Image}}"; docker exec imp-host impz info' < /dev/null
   ```

   Expect `ghcr.io/zgeoff/imp-host:5.0.0@sha256:dd9f3ec3…` and `version 5.0.0`.

3. Point the two upstream secrets back at `docker0`, as
   [Rebind the upstream secrets](#rebind-the-upstream-secrets) describes, with `docker` in place of
   `podman` and `172.17.0.1` in place of `10.88.0.1`.

4. Revert the bump's pull request on `main` with a pull request of its own. `Deploy prod` then
   applies the egress-deny NetworkPolicy and nixie's imp config for `docker0` again, and the next
   host switch from `main` keeps imp 5.0.0.

impd's database needs no restore, because imp 6.0.1 ran no migration on it. When it does need one,
restore the copy from step 1 of the switch with the 5.0.0 generation's own `restore-impd-db`, as
[the restore runbook](./restore-geoff-cloud.md#2-roll-impds-database-back) describes, once the
rollback has run. imp 6's `restore-impd-db` refuses a generation that runs imp-host under Docker.

## Rebind the upstream secrets

impd's database keeps two secrets whose upstream is a listener on imp-host's bridge: `op-connect`
sends to the Connect relay, and `preview-model-counted` to the preview model route listener. The
bridge's address is part of each secret's binding, so a move between `docker0` and `podman0` needs a
rebind. A rebind revokes the secret from every imp and gives it a new generation, so each token's
grantable list and each grant need the secret named again. The steps below point both at
`10.88.0.1`. Run them from a machine where `op` reads the `cloud` vault.

1. Record which imps hold each secret, and each token's grantable list:

   ```bash
   ssh root@geoffcloud podman exec imp-host impz secret ls < /dev/null
   ssh root@geoffcloud podman exec imp-host impz token ls < /dev/null
   ```

   Expect `op-connect` and `preview-model-counted` with their old upstream and the imps they are
   granted to.

2. Rebind `op-connect`, with the token on stdin:

   ```bash
   op read op://cloud/onepassword-connect-token/credential | ssh root@geoffcloud podman exec -i imp-host \
     impz secret add op-connect --kind custom --hosts op-connect.imp.internal --header authorization \
     --scheme bearer --upstream http://10.88.0.1:18081 --replace --rebind
   ```

   Expect the answer to count the grants it dropped.

3. Rebind `preview-model-counted` the same way:

   ```bash
   op read op://cloud/nixie-model-credential/credential | ssh root@geoffcloud podman exec -i imp-host \
     impz secret add preview-model-counted --kind custom --hosts api.anthropic.com --header authorization \
     --scheme bearer --upstream http://10.88.0.1:18082 --replace --rebind
   ```

4. Set each token's grantable list from step 1 again, so it names the new generation, for
   `atc-cloud` and `preview` at least:

   ```bash
   ssh root@geoffcloud podman exec imp-host impz token set <token_name> --grantable '<grantable_list>' < /dev/null
   ```

5. Grant `op-connect` again to each imp that step 1 listed for it, with
   `impz grant <imp_name> op-connect`. Remove each preview imp that held `preview-model-counted`,
   with `impz rm <imp_name>`: its next boot takes the grant itself.

6. Check the bindings:

   ```bash
   ssh root@geoffcloud podman exec imp-host impz secret ls < /dev/null
   ```

   Expect `op-connect.imp.internal -> http://10.88.0.1:18081` and
   `api.anthropic.com -> http://10.88.0.1:18082`, with the imps from step 5.
