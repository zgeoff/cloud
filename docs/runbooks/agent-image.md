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
| `images/agent/VERSION`              | the image version; the imp image is `agent-<VERSION>`   |
| `scripts/check-agent-image.sh`      | the version sweep, login-state check and secret scan    |
| `scripts/agent-image-gitleaks.toml` | gitleaks' default rules, less named upstream test files |
| `/opt/auto-mode/mods/auto-mode`     | the auto-mode mod in the guest, for `--plugin-dir`      |

Each build gets a new imp image name, so the image that ran before stays on the host for a rollback.

## Build

Build from a clean checkout of the commit you record, on a machine whose `imp` CLI calls the
geoffcloud host. The token needs `manage` scope with no imp patterns.

```sh
imp image build images/agent --name "agent-$(cat images/agent/VERSION)"
imp image ls
```

`imp image ls` shows a short digest. Read the full one with
`imp image ls --json | jq -r '.[] | select(.name == "agent-<VERSION>") | .digest'`, and record the
commit, the name and the digest on the PR.

## Check

Boot a fresh imp from the image, run the check, then remove the imp:

```sh
imp new agent-check --image "agent-$(cat images/agent/VERSION)"
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
"cloud": { "provider": "imp", "image": "agent-1", "...": "..." }
```

1. Copy the file to `config.json.bak-<UTC stamp>-pre-<issue or agent-VERSION>`. Other sessions can
   write the same file, so read it again just before the edit.
2. Set `targets.cloud.image` and change nothing else:

   ```sh
   f=~/.config/atc/config.json
   jq --arg image "agent-$(cat images/agent/VERSION)" '.targets.cloud.image = $image' "$f" > "$f.new"
   chmod 600 "$f.new" && mv "$f.new" "$f"
   ```

3. Restart the daemon when no session needs it. The daemon reads its targets at startup only, so the
   change reaches the next spawn after the restart.
4. Spawn a session on `cloud`, and check that its imp runs the new image: `imp ls` shows the image
   of each imp.

A switch changes new imps only. An imp keeps the image it was created from.

## Update

1. Change the pins in `images/agent/Dockerfile`. Check each new sum with the command in the comment
   above its pin.
2. Add one to `images/agent/VERSION`.
3. Run `bun run test:agent-image`, and open a PR.
4. After CI passes, build and check the new image on the host, as above, and record the digest.
5. Switch the `cloud` target.
6. Keep the image the target ran before, for a rollback. Remove an older one with
   `imp image rm agent-<N>`; imp refuses to remove an image that an imp uses.

## Roll back

A rollback points the `cloud` target at the image it ran before: `agent-<VERSION - 1>`, or `coder`
before the first agent image.

1. Check that the earlier image is still on the host: `imp image ls`.
2. Set `targets.cloud.image` to it, as in the switch, and restart the daemon.
3. Spawn a session on `cloud`, and check its imp's image with `imp ls`.

Imps created from the new image keep it. Remove them, or let their sessions end, when the image is
at fault.
