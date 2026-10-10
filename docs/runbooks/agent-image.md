# Agent image

`images/agent` is the imp image that agent sessions run on: `imp-base` plus the tools a session
needs, each at a pinned version and checked against a published sum. atc's `cloud` execution target
names it. It replaces imp's `dev` and `coder` images, so imp ships `imp-base` only.

The image holds binaries only. It holds no configuration, no login state and no secret: atc sets up
grants, placeholder variables, the config bundle and the seed for each session at launch. Its build
runs no tool, because a tool can write state when it runs (`codex --version` creates `~/.codex`).

| Path                                | Holds                                                   |
| ----------------------------------- | ------------------------------------------------------- |
| `images/agent/Dockerfile`           | the pins, each with the command that checks its sum     |
| `scripts/check-agent-image.sh`      | the version sweep, login-state check and secret scan    |
| `scripts/agent-image-gitleaks.toml` | gitleaks' default rules, less named upstream test files |
| `/opt/auto-mode/mods/auto-mode`     | the auto-mode mod in the guest, for `--plugin-dir`      |
| `/usr/local/bin/atc`                | atc in the guest, which the `cloud` target's hooks use  |

Each image is named `agent-<short sha>`, after the zgeoff/cloud commit on `main` it builds from. So
each build gets a new imp image name, and the image that ran before stays on the host for a
rollback.

## Build

Build from a clean checkout of the merge commit on `main`, on a machine whose `imp` CLI calls the
geoffcloud host. The token needs `manage` scope with no imp patterns.

```sh
git switch --detach <merge commit> && git status --short   # prints nothing
image="agent-$(git rev-parse --short HEAD)"
imp image build images/agent --name "$image"
imp image ls
```

`imp image ls` shows a short digest. Read the full one with
`imp image ls --json | jq -r --arg image "$image" '.[] | select(.name == $image) | .digest'`, and
record the name and the digest on the PR.

## Check

Boot a fresh imp from the image, run the check, then remove the imp:

```sh
imp new agent-check --image "$image"
bash scripts/check-agent-image.sh --imp agent-check
imp rm agent-check
```

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

1. Copy the file to `config.json.bak-<UTC stamp>-pre-<issue or image>`. Other sessions can write the
   same file, so read it again just before the edit.
2. Set `targets.cloud.image` and `targets.cloud.guestATC`, and change nothing else:

   ```sh
   f=~/.config/atc/config.json
   jq --arg image "agent-<short sha>" \
     '.targets.cloud.image = $image | .targets.cloud.guestATC = "/usr/local/bin/atc"' "$f" > "$f.new"
   chmod 600 "$f.new" && mv "$f.new" "$f"
   ```

3. Restart the daemon when no session needs it. The daemon reads its targets at startup only, so the
   change reaches the next spawn after the restart.
4. Spawn a session on `cloud`, and check that its imp runs the new image: `imp ls` shows the image
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
- It does nothing when `main` or the branch already pins that release or a newer one, so an older
  release's job that finishes last never moves the pin back.
- The `auto-merge` job in `.github/workflows/agent-image.yml` runs after the image check passes. It
  runs only for the release bot's pull request from this repository's `atc-pin/agent-image` branch.
  `scripts/check-atc-pin-diff.sh` proves that the diff changes the two atc pins and nothing else,
  and the job then runs `gh pr merge --auto --squash` against the head commit it checked. The
  ruleset's required checks still gate the merge.

Any other change to that branch fails the diff check, and the pull request then waits for a person.
The check stops mistakes, not a hostile writer: the ruleset needs no approval, so any token that can
push here can already merge.

If the release job's step fails, pin the release by hand from a clean checkout of `main`:

```sh
gh release download "@zgeoff/atc@$VERSION" -R zgeoff/atc -p SHA256SUMS -D /tmp/atc-sums
bash scripts/open-atc-pin-pr.sh "$VERSION" /tmp/atc-sums/SHA256SUMS
```

After the pin merges, build and check the image, then switch the `cloud` target, as above.

## Update

1. Change the pins in `images/agent/Dockerfile`. Check each new sum with the command in the comment
   above its pin.
2. Open a PR. CI's `agent image` job runs `bun run test:agent-image` on every change to the image or
   its check; run it locally first to find a failure sooner.
3. After the PR merges, build and check the new image on the host from the merge commit, as above,
   and record its name and digest on the PR.
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
