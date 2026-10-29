# Workflows

Common tasks on geoff.cloud. Each change lands through a squash PR to `main`; run live changes from
a clean checkout of `main`.

**CAUTION:** No live change without a preview first. A change that costs money, deletes data or
cannot be undone needs the owner's approval of its exact effect.

## Change infrastructure

1. Edit `infra/`, and open a PR.
2. Preview it. The preview changes nothing:

   ```sh
   bun run sdk:build
   bun run preview
   ```

   Read every replace and delete. If the preview changes the tailnet policy, the owner reviews the
   diff first: Pulumi replaces the whole policy file.

3. Merge it. Once CI passes on `main`, the `Deploy prod` workflow checks drift from the deployed
   revision, previews, applies and checks drift again, unless its guard holds the plan.
   [The prod apply job](./prod-apply.md) covers reading its run and answering a held one.
4. Link the run on the PR or issue. Its log holds both drift results.

Pass Pulumi flags after `--`, such as `bun run preview -- --diff`.

### Apply by hand

Apply by hand only for what the job cannot do, such as a first apply before the job is set up.

**CAUTION:** Check that no `Deploy prod` run is in progress first
(`gh run list --workflow deploy-prod.yml --status in_progress`). Two applies at once race on the
stack.

1. Check the baseline from a clean checkout of the revision at the tag `deployed/prod`, or of the
   last revision applied by hand:

   ```sh
   bun run drift
   ```

   It exits non-zero on any change, so it expects 0 changes only against the deployed code. Record
   the revision and the result. Resolve drift before you go on.

2. From a clean current `main`, preview against the live state:

   ```sh
   bun run preview -- --refresh
   ```

   Expect exactly the intended changes, reviewed on their PRs, and nothing else.

3. Apply:

   ```sh
   bun run up
   ```

4. Run `bun run drift` again, and expect 0 changes. Record both drift results on the PR or issue.
5. Once `deployed/prod` exists, move it to the revision you applied, so the job's next run starts
   from it:

   ```sh
   git tag -f deployed/prod <revision>
   git push --force origin refs/tags/deployed/prod
   ```

### Change stack config

Stack config lives in `infra/Pulumi.prod.yaml`, under the namespace `geoff-cloud`. Set a key from
`infra/`, through `op run` so Pulumi can decrypt the stack:

```sh
cd infra
op run --env-file=../.env -- pulumi config set --stack prod <key> <value>
```

Land the YAML change through a PR, which the apply job applies after the merge.
`infra/Pulumi.prod.yaml` holds the keys, and the program's input loaders describe each one.

## Switch the host

The host is the flake in `nixos/`. Build first, then switch, from a clean checkout of `main`. Both
run in a `nixos/nix` container on the host network, so you need no local Nix. Tailscale SSH
authenticates `root@geoffcloud`. The Docker volume `geoffcloud-nix-store` keeps the Nix store
between runs.

Run the script, which builds, then switches only after the build exits 0:

```sh
bash scripts/switch-geoffcloud.sh               # build, switch, check the host runs the build
bash scripts/switch-geoffcloud.sh --build-only  # build and print the system path
bash scripts/switch-geoffcloud.sh --allow-k3s-restart  # switch in a planned k3s window
```

1. It refuses a branch other than `main`, uncommitted changes, a `main` behind `origin/main`, or any
   git command that fails.
2. It refuses a commit that no green run of the NixOS checks covers, as
   [Check the host before a switch](#check-the-host-before-a-switch) describes. `--build-only` skips
   this gate, because it reaches no host.
3. It refuses a commit whose atc daemon pin is another atc major release than a running atc gateway
   pod's image, or that finds no gateway pod, because atc breaks the daemon protocol only in a major
   release and the daemon handshake does not catch the break. It checks again before the activation.
   For an atc major bump, review and merge the pull request that pins the atc-gateway images'
   digests, which the atc-gateway images workflow opens once it publishes them, let the
   `Deploy prod` workflow roll it out, then switch. `--build-only` skips this gate too.
4. It refuses a commit whose impd, the imp-host image's release, is a major release that a running
   nixie pod refuses, or that finds no nixie pod, because nixie then retries its start without end
   while every host check passes. A nixie pod accepts the major of its imp client, whose version the
   script reads from the `bun.lock` of the pod's nixie release on GitHub: `@impz/client` from nixie
   0.35.1, and `@zgeoff/imp-client` before it. It accepts impd 2 beside a 1.x client from nixie
   0.28.0 on. From nixie 0.42.0 it also accepts each major in the `EXTRA_IMPD_MAJORS` set of its imp
   adapter, which the script reads from the release's source on GitHub. The script checks again
   before the activation. For an impd major bump, deploy a nixie release that accepts the new major
   first. `--build-only` skips this gate too.
5. It refuses a commit whose impd stores a secret kind that the commit's atc daemon pin does not
   accept, and names each such kind, because atc's auth binding then refuses every brokered secret
   of that kind and every cloud spawn and adopt fails with `auth_secret_mismatch`. It reads impd's
   kinds from the `SecretKindSchema` enum in `zgeoff/impz` at the imp-host release's tag, and atc's
   from the `BrokerSecretKind` union in `zgeoff/atc` at the pin's tag. For an impd that adds a kind,
   pin an atc release that accepts it first. `--build-only` skips this gate too.
6. It builds a `git archive` snapshot of that commit with `nix build --no-link`, so untracked files
   and edits made during the run never reach the build. A failed build stops the script, and nothing
   reaches the host.
7. It copies the built store path to the host with `nix copy`, then runs the copied system's
   `switch-to-configuration dry-activate`, which changes nothing and lists the units the activation
   would stop and restart. It holds the switch with exit 1 and those lines when either list holds
   `k3s.service`, because nixie can stay down for minutes after k3s restarts. In a planned k3s
   window, run the switch again with `--allow-k3s-restart`: it prints the same lines and goes on.
8. It sets the system profile to the built store path and runs its `switch-to-configuration switch`
   under `systemd-run`, as `nixos-rebuild` does. The flake is not evaluated again. Before the
   activation it appends the commit and the store path to `/var/lib/host-build-lag/switches` on the
   host, because the store path does not name the commit it was built from.
9. It fails unless the host's `/run/current-system` is the built path, then prints
   `systemctl --failed`, which should list nothing.
10. It runs `nixie health` in nixie's pod for its readiness report, up to 30 times 10 s apart, and
    fails with each readiness or dependency part that is not ready and nixie's reason for it, since
    a host that switches cleanly can still leave nixie unable to start. It prints each advisory part
    that is not ready, such as `conversation_turns`, and passes, because nixie answers while its
    turns fail.
11. It fails with each image record in impd whose build folder holds no `rootfs.ext4`, because every
    imp boot from that image then fails with ENOENT. A database restored across a change of the
    preview image can leave such a record, as
    [the restore runbook](./restore-geoff-cloud.md#2-roll-impds-database-back) describes.
12. It fails with both counts when the host reserved fewer hugetlb pages than its system configures
    in `vm.nr_hugepages`, because impd refuses each boot and wake that the free pool cannot hold.
    The activation reserves a changed pool on the running host, where fragmented memory can leave it
    short. Reboot the host, which reserves the whole pool early in boot, then run the switch again.
13. It pushes the tag `deployed/host` on `origin` to the switched commit and prints
    `== deployed/host moved to <commit>`. The tag marks the commit the host runs, as `deployed/prod`
    marks the commit the `Deploy prod` workflow applied, so a change that reaches prod only through
    a switch counts as shipped once the host runs it. A switch that fails any earlier step leaves
    the tag where it was. The push forces the tag, because the last activation decides what the host
    runs, even when it activates an older commit. When `origin` refuses the push, the script exits
    with git's code and prints the `git push --force origin <commit>:refs/tags/deployed/host` that
    moves the tag by hand.

A timer on the host checks every hour whether it runs an older system or imp than the latest green
NixOS checks run on `main`, and after a day of that the `HostBehindLatestBuild` alert fires, as
[the troubleshooting runbook](./troubleshooting.md#hostbehindlatestbuild-or-hostbuildlagstale-fires)
describes. A switch clears it.

`bash scripts/test-switch-geoffcloud.sh` (part of `bun run test:scripts`) checks the gates with stub
`gh`, `docker` and `ssh`. After a switch, `ssh root@geoffcloud k3s kubectl get nodes` should show
the node `Ready`.

Before a risky host change, take an Onidel snapshot of the root disk:

```sh
op run --env-file=.env -- bun run onidel:snapshot pre-<change>
```

The flake also has checks: one for each of its modules and one for the impd database tools,
`test-utils` for the helpers and the stand-in impd they share, and `impd-restore` and
`impd-restore-boundaries`, NixOS VM rehearsals of `restore-impd-db` on one shared machine that need
KVM: `impd-restore-boundaries` holds the errors only a stand-in `systemctl` or `cmp` reaches.
`bun run test:nixos` builds every check the flake declares in a `nixos/nix` container, from a
snapshot of the working tree's tracked and unignored files. Its Nix store is the Docker volume
`cloud-nixos-checks-store`, never the switch's `geoffcloud-nix-store`.
`bun run test:nixos atc-daemon` builds one check.

### Check the host before a switch

The NixOS checks gate the switch, not the merge. The `NixOS checks` workflow runs on `main` every
night and on each dispatch, on `main` or on a branch. It also runs on each push to a pull request
that changes an input of the checks, a release bump included, so a break shows before the merge; the
merge does not wait for it, and the switch never counts it. A Renovate pull request starts no run;
the nightly run checks its bump.

A run builds nothing, and passes, in two cases. A green scheduled or dispatched run on `main` covers
every later commit that changes no input of the checks, which the `nixos` gate of
[`gates.yml`](../../.github/gates.yml) lists. A run also skips the build when an earlier run built
and passed the same derivations with the same workflow and build scripts, wherever that run ran; the
skipped run's summary links it. A dispatch with `-f force=true` always builds.

Runs on one commit of `main` queue, so the later one finds the earlier one's result. A newer
dispatch on a branch cancels the branch's older run. A build substitutes the store paths it needs
from `main`'s Actions cache of the paths that cache.nixos.org does not serve, and a build on `main`
replaces that cache.

To switch before the nightly run covers the commit:

1. Start a run on `main`:

   ```sh
   gh workflow run nixos-checks.yml --ref main
   ```

2. Find the run's id, the first column of the newest `workflow_dispatch` row, and wait for it:

   ```sh
   gh run list --workflow nixos-checks.yml --branch main --limit 3
   gh run watch <run_id> --exit-status
   ```

   Expect exit 0. A failed run means the commit breaks a check: fix it in a PR rather than
   switching.

3. Run `bash scripts/switch-geoffcloud.sh`. Expect its first line to be `== checked by <run url>`.

`bash scripts/find-nixos-check-run.sh <commit>` prints the run that covers a commit, or nothing.

## Upgrade imp

imp is pinned in three places, and the imp release pin moves all three together, in a bump pull
request or [by hand](./release-check.md#pin-a-release-by-hand):

| Pin                  | File                                                                                                                   |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| imp's NixOS module   | the `imp` input in `nixos/flake.nix`, and `nixos/flake.lock`                                                           |
| the `imp-host` image | `services.imp.image` in `nixos/hosts/geoffcloud/configuration.nix`, by tag and digest                                  |
| the `imp-base` image | the `FROM` in `images/agent/Dockerfile`, and `services.preview.impRegistryImage` in the host config, by tag and digest |

The [release check](./release-check.md) opens the bump pull request for each new imp release on the
`release-check/imp` branch, with all three pins moved. The `release bump merge` workflow merges it
once its checks pass, unless its labels hold it for a person, as
[When a bump merges on its own](./release-check.md#when-a-bump-merges-on-its-own) describes. The
merge changes nothing on the host. The steps after it stay with a person, and the pull request's
body lists them:

1. Read imp's release notes for migrations and new host settings: before you merge a bump labelled
   `needs-review`, or after the merge for one that merged on its own.
2. Copy impd's database. Never tar the live files:

   ```sh
   bash scripts/copy-impd-db.sh imp-<old version>-pre-<new version>
   ```

   The copy and its `COPY-INFO` land in `/root/imp-db-backups/`.
   [The restore runbook](./restore-geoff-cloud.md#2-roll-impds-database-back) puts a copy back.

3. [Switch the host](#switch-the-host). The switch restarts impd.
4. Check: `ssh root@geoffcloud podman exec imp-host impz info` shows the new version,
   `https://imps.geoff.cloud/health` answers 200 from the tailnet, and the `imp` dashboard in
   Grafana shows impd's logs.
5. Rebuild the agent image on the new imp-base, as [the agent image runbook](./agent-image.md)
   describes.

A merged bump that waits a day for the switch fires the `HostBehindLatestBuild` alert.

The move from imp 5.0.0 on Docker to imp 6.0.0 on Podman takes more steps, which
[the Podman switch runbook](./imp-podman-switch.md) lists.

impd's database lives in `tank/imp`, which has a legacy mountpoint inside imp-host. The host's
`/var/lib/imp` is empty.

## Observe

[The observe runbook](./observe.md) covers Grafana, the Loki and Prometheus queries, the external
health check, and turning Discord alerts on or off.

## Rotate a credential

Store the new value in its 1Password item first, then deliver it. An item `.env` references has a
copy in the vault `cloud-deploy` for the apply job: update both. The passphrase and the alert
webhook have a third copy in the host's credentials file for the
[scheduled drift check](./drift-check.md#rotate-the-checks-credentials): install that file again
after a change to either.

| Credential                                                     | Deliver it with                                                                                       |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| a provider credential: Onidel, Cloudflare, Tailscale, R2 state | nothing: the next run reads the new value through `op run`. Revoke the old one at its source          |
| `ALERT_WEBHOOK_URL`                                            | `bun run up`, which updates the Worker's secret, and Alertmanager's Secret when `discordAlerts` is on |
| `ALERT_MENTION_USER_ID`                                        | `bun run up`, which updates Alertmanager's Secret and restarts it when `discordAlerts` is on          |
| `PULUMI_CONFIG_PASSPHRASE`                                     | do not replace the item: the stack's secrets are encrypted with it. Changing it needs a migration     |
| imp's Cloudflare DNS token                                     | `bash scripts/install-imp-dns-token.sh`; impd rereads the file, no restart                            |
| the k3s kubeconfig                                             | `bash scripts/connect-k3s.sh`, then a preview. Read it before any apply                               |
| `GHCR_PULL_TOKEN`                                              | the apply bracket in [the GHCR pull token](./ghcr-pull-token.md#rotate-the-token), then a pull check  |
| imp's tailnet key (`tag:imp`)                                  | `bun run up` mints a new one after expiry and writes it to `imp-tailscale-authkey`                    |

A rotation of the atc daemon's gateway or imp token needs `systemctl restart atc-daemon` on the
host, because the daemon reads copies of the token files made when it starts
([the cloud daemon](../architecture/workloads/atc-gateway.md#the-cloud-daemon)).

## Reinstall the host

Follow [the reinstall runbook](./reinstall-geoffcloud.md). It wipes `vda` only; imp's pool on `vdb`
survives.

## Recover

[The restore runbook](./restore-geoff-cloud.md) covers imps, impd's database, the host, the root
disk and the cluster. The atc gateway has
[its own backup and restore runbook](./atc-gateway-backup-restore.md).
