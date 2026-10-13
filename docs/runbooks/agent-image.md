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
service prints its choice and the free space it read, which `imp logs <name> swap` shows.
`images/agent/sbin/setup-swap` holds the bounds and the reason for each.

The image holds no other configuration, no login state and no secret: atc sets up grants,
placeholder variables, the config bundle and the seed for each session at launch. Its build runs no
tool, because a tool can write state when it runs (`codex --version` creates `~/.codex`).

| Path                                  | Holds                                                   |
| ------------------------------------- | ------------------------------------------------------- |
| `images/agent/Dockerfile`             | the pins, each with the command that checks its sum     |
| `scripts/check-agent-image.sh`        | the version sweep, login-state check and secret scan    |
| `scripts/agent-image-gitleaks.toml`   | gitleaks' default rules, less named upstream test files |
| `/opt/auto-mode/mods/auto-mode`       | the auto-mode mod in the guest, for `--plugin-dir`      |
| `/usr/local/bin/atc`                  | atc in the guest, which the `cloud` target's hooks use  |
| `/etc/imp/services.d/overcommit.json` | the boot service that sets `vm.overcommit_memory=1`     |
| `/etc/imp/services.d/swap.json`       | the boot service that runs `/usr/local/sbin/setup-swap` |

Each image is named `agent-<short sha>`, after the zgeoff/cloud commit on `main` it builds from. So
each build gets a new imp image name, and the image that ran before stays on the host for a
rollback.

## Build

Build and check in one command, from any zgeoff/cloud clone, on a machine whose `imp` CLI calls the
geoffcloud host. The token needs `manage` scope with no imp patterns.

```sh
bash scripts/build-agent-image.sh            # origin/main's head, after a fetch
bash scripts/build-agent-image.sh <commit>   # or an older commit on main
```

The script builds from a `git archive` of the commit, so the clone's working tree never reaches the
image. It names the image `agent-<short sha>`, then boots the imp `agent-check-<short sha>` from it,
runs that commit's `scripts/check-agent-image.sh` there, and removes the imp. Its last line is
`agent-<short sha> <digest> check passed`; record that line on the PR. A failed check removes the
image, unless `--keep` keeps it for a look, and every failure exits 1. It refuses a commit that is
not on `main`, and an image or check imp name that already exists.

`imp image build` prints no progress off a terminal, so the build runs quietly for several minutes.
`AGENT_IMAGE_BUILD_TIMEOUT` (45m by default) stops a build that hangs. impd can still finish that
build afterwards, so read `imp image ls` before a retry.

## Check

The check prints one line per item and exits non-zero on any failure:

- **Login state**: none of the files a tool writes when it signs in exists under `/root` or
  `/home/*`, and no environment variable has a credential-like name. It runs first, before any tool.
- **Secrets**: gitleaks 8.30.1 scans each top-level folder but `/proc`, `/sys`, `/dev` and `/run`,
  with `--redact`. It skips files over 50 MB: the pinned binaries, whose sums the build checks.
- **Versions**: each tool answers with the version the Dockerfile pins, and each Ubuntu package is
  installed at its pinned version.

`bun run test:agent-image` runs the same check on a local Docker build, before the host build. A
finding in an upstream file that holds no credential goes into `scripts/agent-image-gitleaks.toml`
with its reason, narrowed to that file or folder.

## Switch the `cloud` target

The `cloud` target lives in `~/.config/atc/config.json` on the machine that runs the atc daemon:

```json
"cloud": { "provider": "imp", "image": "agent-<short sha>", "guestATC": "/usr/local/bin/atc", "...": "..." }
```

`guestATC` points the session hooks at the image's atc, so the daemon never copies its own binary
into a fresh imp. Without it, a compiled daemon uploads its binary, about 100 MB, before each new
imp's first session starts.

1. Run `bash scripts/switch-agent-image.sh agent-<short sha>` on the machine that runs the daemon.
   It refuses an image the host lacks, copies the config to
   `config.json.bak-<UTC stamp>-pre-<image>`, then sets `targets.cloud.image` and
   `targets.cloud.guestATC` and changes nothing else. A second argument names another config file.
2. Restart the daemon when no session needs it, with the command the script prints,
   `atc daemon restart`. It restarts the daemon through its systemd unit and restores the fleet;
   `--dry-run` first lists the sessions a restart interrupts. The script never restarts it. The
   daemon reads its targets at startup only, so the change reaches the next spawn after the restart.
3. Spawn a session on `cloud`, and check that its imp runs the new image: `imp ls` shows the image
   of each imp.

A switch changes new imps only. An imp keeps the image it was created from.

## A new atc release

atc's release job opens the pin pull request itself. After it attaches the release's binaries, it
mints a release bot token scoped to zgeoff/cloud, clones this repository, and runs
`scripts/open-atc-pin-pr.sh <version> <SHA256SUMS>` with the SHA256SUMS it just published:

- The script builds the `atc-pin/agent-image` branch from `main` with `scripts/pin-agent-atc.sh`,
  which changes only `ARG ATC_VERSION` and `ARG ATC_SHA256`. It then opens one pull request,
  `chore: pin atc <version> in the agent image`. A later release replaces the branch and updates the
  same pull request. It turns that pull request's auto-merge off first, so the new pin waits for its
  own checks.
- It does nothing when `main` already pins that release or a newer one, or the branch pins a newer
  one, so an older release's job that finishes last never moves the pin back. When the branch
  already pins that release, it pushes nothing and opens the pull request if none is open, so
  running it again repairs a run that failed after its push.
- The `auto-merge` job in `.github/workflows/agent-image.yml` runs after the image check passes. It
  runs only for the release bot's pull request from this repository's `atc-pin/agent-image` branch.
  `scripts/check-atc-pin-diff.sh` proves that the diff changes the two atc pins and nothing else,
  and the job then runs `gh pr merge --auto --squash` against the head commit it checked. The
  ruleset's required checks still gate the merge.

Any other change to that branch fails the diff check, and the pull request then waits for a person.
The check stops mistakes, not a hostile writer: the ruleset needs no approval, so any token that can
push here can already merge.

The [release check](./release-check.md) also pins each new atc release here, on its own branch and
together with the host's daemon and the gateway images. If the release job's step fails, pin the
release by hand from a clean checkout of `main`:

```sh
gh release download "@zgeoff/atc@$VERSION" -R zgeoff/atc -p SHA256SUMS -D /tmp/atc-sums
bash scripts/open-atc-pin-pr.sh "$VERSION" /tmp/atc-sums/SHA256SUMS
```

After the pin merges, roll the release out in the order that
[Roll out an atc release](#roll-out-an-atc-release) gives.

## Roll out an atc release

A daemon whose atc differs from the atc in its `cloud` target's image copies its own binary into
each imp it wakes, before the imp's first session starts. A restore of a busy fleet after the
daemon's restart then waits on one upload per imp. So the image that ships a release reaches the
`cloud` target before the daemon runs that release. The daemon reads its targets at startup only, so
one restart brings the new release and the new image together.

Run these steps on the machine that runs the daemon, after the pin pull request merges. `$VERSION`
is the release, such as `4.5.0`.

1. Build and check the image from `main`'s head:

   ```bash
   bash scripts/build-agent-image.sh
   ```

   Expect its last line to read `agent-<short sha> <digest> check passed`. Record that line on the
   pin pull request.

2. Check that the image's commit pins the release:

   ```bash
   git fetch origin main
   git show <short sha>:images/agent/Dockerfile | grep '^ARG ATC_VERSION='
   ```

   Expect `ARG ATC_VERSION=$VERSION`. The image check proves that the image's atc answers with the
   version its Dockerfile pins, so this line proves the image ships the release.

3. Switch the `cloud` target, and leave the daemon running:

   ```bash
   bash scripts/switch-agent-image.sh agent-<short sha>
   ```

   The script prints `atc daemon restart`. Wait for step 4 to run it.

4. Install the release binary over the one the daemon's systemd unit starts, then restart the
   daemon:

   ```bash
   bin="$(command -v atc)"
   gh release download "@zgeoff/atc@$VERSION" -R zgeoff/atc -p atc-linux-x64 -p SHA256SUMS -D "/tmp/atc-$VERSION"
   (cd "/tmp/atc-$VERSION" && grep ' atc-linux-x64$' SHA256SUMS | sha256sum -c -)
   install -m 0755 "/tmp/atc-$VERSION/atc-linux-x64" "$bin.new" && mv "$bin.new" "$bin"
   atc daemon restart --dry-run
   atc daemon restart
   ```

   The `mv` replaces the binary in one rename, so the running daemon keeps its open file. Run the
   restart when the dry run lists no session that needs the daemon. atc's install script installs
   the newest release, which may not be the one the image pins, so this step downloads `$VERSION` by
   name.

5. Wake an imp on `cloud`, such as by a spawn, and read the daemon's journal:

   ```bash
   journalctl --user -u atc-daemon --since -10min | grep 'runs hooks through'
   ```

   Expect `runs hooks through the image's atc $VERSION at /usr/local/bin/atc` for each wake. A line
   that reads `runs hooks through the daemon's atc $VERSION, copied to /tmp/atc/bin/atc` means the
   target's image ships another atc: go back to step 2.

## A new auto-mode release

The [release check](./release-check.md) opens the `release-check/auto-mode` pull request for each
new auto-mode release. `scripts/pin-auto-mode.sh` writes the pin from the npm tarball, after it
checks the tarball against npm's integrity hash and the version in its `package.json`. To pin a
release by hand, run it from a clean checkout of `main`:

```sh
curl -fsSL -o /tmp/auto-mode.tgz "https://registry.npmjs.org/auto-mode/-/auto-mode-$VERSION.tgz"
bash scripts/pin-auto-mode.sh "$VERSION" /tmp/auto-mode.tgz "$(npm view "auto-mode@$VERSION" dist.integrity)"
```

The image's gitleaks allowlist (`scripts/agent-image-gitleaks.toml`) names the file in the auto-mode
tarball that holds its secret-scanner rules. The image check on the bump pull request fails when a
release moves those rules or ships another finding, and the bump then waits for a person to review
the allowlist entry.

## Update

1. Change the pins in `images/agent/Dockerfile`. Check each new sum with the command in the comment
   above its pin.
2. Open a PR. CI's `agent image` job runs `bun run test:agent-image` on every change to the image or
   its check; run it locally first to find a failure sooner.
3. After the PR merges, run `bash scripts/build-agent-image.sh`, and record its last line on the PR.
4. Switch the `cloud` target.
5. Keep the image the target ran before, for a rollback. Remove an older one with
   `imp image rm agent-<short sha>`; imp refuses to remove an image that an imp uses.

## Roll back

A rollback points the `cloud` target at the image it ran before: the `agent-<short sha>` its PR
records, `agent-1` before the first image named for a commit, or `coder` before the first agent
image. An image without atc, such as `agent-1` or `coder`, needs `guestATC` removed from the target
too, so the daemon copies its binary in again.

1. Check that the earlier image is still on the host: `imp image ls`.
2. Set `targets.cloud.image` to it, as in the switch, and restart the daemon.
3. Spawn a session on `cloud`, and check its imp's image with `imp ls`.

Imps created from the new image keep it. Remove them, or let their sessions end, when the image is
at fault.
