# Agent image

`images/agent` is the imp image that agent sessions run on: `imp-base` plus the tools a session
needs, each at a pinned version and checked against a published sum. atc's `cloud` execution target
names it. It replaces imp's `dev` and `coder` images, so imp ships `imp-base` only.

The image holds binaries and two boot services for a 2 GiB imp:

- `overcommit` sets `vm.overcommit_memory=1`, so oxlint's allocator can reserve its buffers.
- `swap` creates `/swapfile` at the first boot, turns it on at each boot, and sets `vm.swappiness`
  to the kernel default of 60. A command that needs more memory than the imp holds, such as a
  type-aware lint, then pages out and slows down. Without swap, the imp stops answering.

The swap service sizes `/swapfile` from the free space on `/`, so the swapfile never fills the disk.
A 32 GiB agent imp gets 2 GiB. A small disk, such as a 4 GiB test imp, gets a smaller swapfile or
none, because the service keeps room free for the session's checkout and the broker's files. The
service prints its choice and the free space it read, which `impz logs <name> swap` shows.
`images/agent/sbin/setup-swap` holds the bounds and the reason for each.

Beside them, the image holds one Claude Code hook, which [Locked packages](#locked-packages) covers.
It holds no other configuration, no login state and no secret: atc sets up grants, placeholder
variables, the config bundle and the seed for each session at launch. Its build runs no tool,
because a tool can write state when it runs (`codex --version` creates `~/.codex`).

| Path                                  | Holds                                                     |
| ------------------------------------- | --------------------------------------------------------- |
| `images/agent/Dockerfile`             | the pins, each with the command that checks its sum       |
| `scripts/agent-image-check-guest.sh`  | the version sweep, login-state check and secret scan      |
| `scripts/agent-image-gitleaks.toml`   | gitleaks' default rules, less named upstream test files   |
| `/opt/auto-mode/mods/auto-mode`       | the auto-mode mod in the guest, for `--plugin-dir`        |
| `/usr/local/bin/atc`                  | atc in the guest, which the `cloud` target's hooks use    |
| `/usr/local/bin/bun`                  | the shim that runs the Bun a checkout pins                |
| `/etc/imp/services.d/overcommit.json` | the boot service that sets `vm.overcommit_memory=1`       |
| `/etc/imp/services.d/swap.json`       | the boot service that runs `/usr/local/sbin/setup-swap`   |
| `/etc/claude-code/managed-settings.d` | the SessionStart hook that installs a checkout's packages |

Each image is named `agent-<short sha>`, after the zgeoff/cloud commit on `main` it builds from. So
each build gets a new imp image name, and the image that ran before stays on the host for a
rollback.

## Bun versions

A session runs the Bun version that its checkout pins, so a repo's hooks and tests run on the Bun
its CI runs. The image holds each Bun version that a zgeoff repo pins in its `.bun-version`, one
folder per version under `/opt/bun`. `bun` and `bunx` are a shim that reads the nearest
`.bun-version` from the current folder up to `/` and runs that version. Without a `.bun-version`,
the shim runs the newest version the image holds.

A pin the image lacks also runs the newest version, after a note on stderr that names both versions,
so a session keeps working. When a repo moves its `.bun-version` to a version the image lacks, add
that version to the Dockerfile's Bun pins, then build and switch the image.

## Locked packages

A session's hooks import the package versions that its checkout's `bun.lock` pins, as they do in an
installed checkout on a person's machine. Without `node_modules`, Bun's auto-install would load the
newest published version of an imported package, or whichever version its cache already holds,
because it reads neither `package.json` nor `bun.lock`. A repo's `.claude` hook, such as the skill
gate, would then run another version than the repo pins, and a broken version stays in the cache.

So the image adds a Claude Code SessionStart hook as a managed settings drop-in, which Claude Code
runs beside the hooks of the session's own settings. At each session start in a checkout with a
`bun.lock` and no `node_modules`, `/usr/local/sbin/install-checkout-packages` runs
`bun install --frozen-lockfile` there, before the session's first tool call. A checkout that holds
`node_modules` keeps it. After a failed install, the hook adds one line to the session's context, so
the session runs the install itself.

Claude Code reads the managed settings file only while no server-managed settings apply to the
session. If an organization policy reaches the imp's sessions, that policy needs the same hook.

## Build

The host builds each image itself, as [The host's build](#the-hosts-build) describes: once a commit
that changes `images/agent` lands on `main`, the `agent-image-build` timer runs the build script for
that commit. Run the script yourself only to build another commit, or to build again after a failed
build.

Build and check in one command, from any zgeoff/cloud clone, on a machine whose `impz` CLI calls the
geoffcloud host. The token needs `manage` scope with no imp patterns.

```sh
bun scripts/build-agent-image.ts            # origin/main's head, after a fetch
bun scripts/build-agent-image.ts <commit>   # or an older commit on main
```

Name the commit that changed `images/agent`, as the timer does, so a build by hand and the timer
make the same image name.

The script builds from a `git archive` of the commit, so the clone's working tree never reaches the
image. It names the image `agent-<short sha>`, then boots the imp `agent-check-<short sha>` from it,
runs that commit's `scripts/check-agent-image.ts` there, and removes the imp. Its last line is
`agent-<short sha> <digest> check passed`; record that line on the PR. A passed check pins the image
in impd, because a daemon's target boots it by name, and impd's image eviction would otherwise
remove it while no imp uses it. A failed check removes the image, unless `--keep` keeps it for a
look, and every failure exits 1. It refuses a commit that is not on `main`, and an image or check
imp name that already exists.

`impz image build` prints no progress off a terminal, so the build runs quietly for several minutes.
`AGENT_IMAGE_BUILD_TIMEOUT` (45m by default) stops a build that hangs. impd can still finish that
build afterwards, so read `impz image ls` before a retry.

## The host's build

The `agent-image-build` timer on geoffcloud fetches `main` of the public zgeoff/cloud repository
without a credential, into a clone under `/var/lib/agent-image-build`. It takes the newest commit on
`main` that changes `images/agent`, and runs the build script for that commit when impd holds no
image of its name. While impd does not answer, as when a host switch recreates imp-host, a run waits
up to 10 minutes and then leaves the build to the next run, so the unit does not fail the switch. A
build that fails while imp-host's container changes leaves the commit for the next run as well. It
copies `impz` out of the imp-host container for each build, so the CLI matches the impd it calls.
The build's token is a `manage` token with no imp patterns, so it controls every imp, grant and
image on the host. It lives in a root-only file on the host's encrypted secrets dataset, and never
in a GitHub secret.

Until the token file exists, systemd skips the unit. To stage the token, run this once from a
machine that reaches the host:

```bash
ssh root@geoffcloud 'install -d -m 0700 /var/lib/tank-cloud/host-secrets/agent-image-build && podman exec imp-host impz token new agent-image-build --scope manage | (umask 377 && cat > /var/lib/tank-cloud/host-secrets/agent-image-build/imp-token) && test -s /var/lib/tank-cloud/host-secrets/agent-image-build/imp-token && echo ok' < /dev/null
```

Expect `ok`. impz prints the token on its stdout, which goes straight into the file with mode 0400,
so the token never appears in a command line or the journal. To replace the token, remove the old
one with `podman exec imp-host impz token rm agent-image-build` and run the command again.

Each run writes its decision to the unit's journal, which Alloy ships to Loki, on a line that starts
with `agent-image-build:`. A build adds the build script's progress, and its last line repeats the
script's result line:

```bash
ssh root@geoffcloud journalctl -u agent-image-build --since -1d | grep 'agent-image-build:'
```

Expect `agent-image-build: agent-<short sha> <digest> check passed` after a pin merges. A failed
build fails the unit and records its time in `/var/lib/agent-image-build/failed/<sha>`, and later
runs skip that commit, so a broken commit is built once. Read the build's output in the journal, fix
the cause, then remove that file: the next run builds the commit again. A failure before the build,
such as an imp-host that does not answer, records nothing, and the next run tries again.

## Check

The check prints one line per item and exits non-zero on any failure:

- **Login state**: none of the files a tool writes when it signs in exists under `/root` or
  `/home/*`, and no environment variable has a credential-like name. It runs first, before any tool.
- **Secrets**: gitleaks 8.30.1 scans each top-level folder but `/proc`, `/sys`, `/dev` and `/run`,
  with `--redact`. It skips files over 50 MB: the pinned binaries, whose sums the build checks.
- **Versions**: each tool answers with the version the Dockerfile pins, and each Ubuntu package is
  installed at its pinned version.

`bun run test:agent-image` runs the same check on a local Docker build, before the host build. It
then runs `scripts/test-agent-image-gitleaks.sh`, which scans planted files with the image's
gitleaks to prove what the allowlist exempts and what it still reports. A finding in an upstream
file that holds no credential goes into `scripts/agent-image-gitleaks.toml` with its reason,
narrowed to that file or folder.

## Switch the `cloud` target

The `cloud` target lives in `~/.config/atc/config.json` on the machine that runs the atc daemon:

```json
"cloud": { "provider": "imp", "image": "agent-<short sha>", "guestATC": "/usr/local/bin/atc", "...": "..." }
```

`guestATC` points the session hooks at the image's atc, so the daemon never copies its own binary
into a fresh imp. Without it, a compiled daemon uploads its binary, about 100 MB, before each new
imp's first session starts.

1. Run `bun scripts/switch-agent-image.ts agent-<short sha>` on the machine that runs the daemon. It
   refuses an image the host lacks, copies the config to `config.json.bak-<UTC stamp>-pre-<image>`,
   then sets `targets.cloud.image` and `targets.cloud.guestATC` and changes nothing else. A second
   argument names another config file.
2. Restart the daemon when no session needs it, with the command the script prints,
   `atc daemon restart`. It restarts the daemon through its systemd unit and restores the fleet;
   `--dry-run` first lists the sessions a restart interrupts. The script never restarts it. The
   daemon reads its targets at startup only, so the change reaches the next spawn after the restart.
3. Spawn a session on `cloud`, and check that its imp runs the new image: `impz ls` shows the image
   of each imp.

A switch changes new imps only. An imp keeps the image it was created from.

## A new atc release

The [release check](./release-check.md) opens the `release-check/atc` pull request for each new atc
release. It pins the release everywhere cloud runs atc. In the agent image, it changes only
`ARG ATC_VERSION` and `ARG ATC_SHA256`, and takes the sum of `atc-linux-x64` from the release's
SHA256SUMS. To pin a release by hand, run the manual pin from a clean checkout of `main`:

```sh
bun scripts/release/run-release-pin.ts atc "$VERSION"
```

After the pin merges, roll the release out in the order that
[Roll out an atc release](#roll-out-an-atc-release) gives.

## Roll out an atc release

The daemon copies its own binary into an imp whose image ships another atc, before the imp's first
session starts, so a fleet of such imps waits on one upload per imp. A new imp on an image that
ships the daemon's release skips the copy. So the image that ships a release reaches the `cloud`
target before the daemon runs that release. The daemon reads its targets at startup only, so one
restart brings the new release and the new image together.

An imp that exists at the restart keeps the image it was created from, and takes the upload at its
next wake. Restart the daemon when few imps are live, so few wakes pay for it.

Run these steps on the machine that runs the daemon, after the pin pull request merges. `$VERSION`
is the release, such as `4.5.0`.

1. Wait for the host to build and check the image of the pin's commit, as
   [The host's build](#the-hosts-build) describes:

   ```bash
   ssh root@geoffcloud journalctl -u agent-image-build --since -2h | grep 'check passed'
   ```

   Expect `agent-image-build: agent-<short sha> <digest> check passed`, where `<short sha>` is the
   pin's commit on `main`. Record that line on the pin pull request.

2. Check that the image's commit pins the release:

   ```bash
   git fetch origin main
   git show <short sha>:images/agent/Dockerfile | grep '^ARG ATC_VERSION='
   ```

   Expect `ARG ATC_VERSION=$VERSION`. The image check proves that the image's atc answers with the
   version its Dockerfile pins, so this line proves the image ships the release.

3. Switch the `cloud` target, and leave the daemon running:

   ```bash
   bun scripts/switch-agent-image.ts agent-<short sha>
   ```

   The script prints `atc daemon restart`. Wait for step 4 to run it.

4. Install the release binary over the one the daemon's systemd unit starts, then restart the
   daemon:

   ```bash
   bin="$(command -v atc)"
   gh release download "@zgeoff/atc@$VERSION" -R zgeoff/atc -p atc-linux-x64 -p SHA256SUMS -D "/tmp/atc-$VERSION"
   (cd "/tmp/atc-$VERSION" && grep ' atc-linux-x64$' SHA256SUMS | sha256sum -c -) \
     && install -m 0755 "/tmp/atc-$VERSION/atc-linux-x64" "$bin.new" && mv "$bin.new" "$bin"
   "$bin" --version
   ```

   A failed sum check stops the install. Expect `$VERSION` from the last command, and stop when it
   prints another version, because a restart then runs the old release against the new image. The
   `mv` replaces the binary in one rename, so the running daemon keeps its open file. atc's install
   script installs the newest release, which may not be the one the image pins, so this step
   downloads `$VERSION` by name.

   Restart the daemon when the dry run lists no session that needs it:

   ```bash
   atc daemon restart --dry-run
   atc daemon restart
   ```

5. Spawn a session on `cloud`, so the daemon creates a new imp, and read the daemon's journal:

   ```bash
   journalctl --user -u atc-daemon --since -10min | grep 'runs hooks through'
   ```

   Expect `runs hooks through the image's atc $VERSION at /usr/local/bin/atc` for the new imp. When
   the new imp logs `runs hooks through the daemon's atc $VERSION, copied to /tmp/atc/bin/atc`, the
   target's image ships another atc: go back to step 2. An imp that existed before the restart logs
   that copy line too, as expected.

## A new auto-mode release

The [release check](./release-check.md) opens the `release-check/auto-mode` pull request for each
new auto-mode release. It writes the pin from the npm tarball, after it checks the tarball against
npm's integrity hash and the version in its `package.json`. To pin a release by hand, run the manual
pin from a clean checkout of `main`:

```sh
bun scripts/release/run-release-pin.ts auto-mode "$VERSION"
```

The image's gitleaks allowlist (`scripts/agent-image-gitleaks.toml`) names the two files in the
auto-mode tarball that hold its secret-scanner rules, and exempts only the short-lived Bedrock
rule's pattern source in them. The image check on the bump pull request fails when a release moves
those rules or ships another finding, and the bump then waits for a person to review the allowlist
entry.

## Update

1. Change the pins in `images/agent/Dockerfile`. Check each new sum with the command in the comment
   above its pin.
2. Open a PR. CI's `test-agent-image` job runs `bun run test:agent-image` on every change to the
   image or its check; run it locally first to find a failure sooner.
3. After the PR merges, wait for the host's build line in the journal
   ([The host's build](#the-hosts-build)), and record it on the PR.
4. Switch the `cloud` target.
5. Keep the image the target ran before, for a rollback. Remove an older one with
   `impz image rm agent-<short sha>`; imp refuses to remove an image that an imp uses. The build
   pinned it, so impd's image eviction never removes it: to leave an image that no target boots to
   the eviction instead, unpin it with `impz image unpin agent-<short sha>`.

## Roll back

A rollback points the `cloud` target at the image it ran before: the `agent-<short sha>` its PR
records, `agent-1` before the first image named for a commit, or `coder` before the first agent
image. An image without atc, such as `agent-1` or `coder`, needs `guestATC` removed from the target
too, so the daemon copies its binary in again.

1. Check that the earlier image is still on the host: `impz image ls`.
2. Set `targets.cloud.image` to it, as in the switch, and restart the daemon.
3. Spawn a session on `cloud`, and check its imp's image with `impz ls`.

Imps created from the new image keep it. Remove them, or let their sessions end, when the image is
at fault.
