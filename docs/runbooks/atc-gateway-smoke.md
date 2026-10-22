# atc gateway: smoke spawn

The smoke spawn checks the whole path from a gateway client to an agent turn in an imp. A client
signed in through the atc gateway spawns a Claude session on the cloud daemon's `geoffcloud` target,
and the session runs one prompt in a new imp. Run it after a change to the gateway, the cloud
daemon, its agents or the agent image. The spawn clones a git workspace and opts into trust for that
clone, because a Claude session in any other folder stops at Claude Code's folder-trust dialog and
never runs its prompt.

## The spawn settings

Claude Code asks whether you trust a folder the first time it starts there, and the imp's Claude
config trusts no folder. atc writes trust for one folder into that config only when the spawn clones
a workspace and sets `trustClonedWorkspace: true`. The trust covers the clone's root and nothing
else, so a spawn into `/root` or any other existing folder still stops at the dialog. atc accepts
the opt-in on an imp target only for an agent that signs in through impd's broker, which the
daemon's `claude` does.

The spawn passes these settings:

- `workspace` is a git source over HTTPS with a `ref`. The cloud daemon resolves the ref with git on
  the host, and the imp clones the repository itself.
- `trustClonedWorkspace` is `true`.
- `cwd` is left out. atc then clones into a folder under the imp user's home that it names after the
  repository and the ref, and the session entry's `cwd` holds that folder.

The workspace is `zgeoff/coderabbit`, a public repository of two files with no `.claude` folder. The
session reads the clone's own Claude settings, so a repository with hooks runs them before the
smoke's tool calls; this repository's skill gate is one such hook. atc refuses a brokered spawn into
a clone whose Claude settings set an `apiKeyHelper` or a sign-in variable in `env`, because those
settings would route around the broker.

## Installed agents

`atc_spawn_options_get` reports `installed: false` for `claude` and `codex` on the cloud daemon, and
that is expected. atc sets `installed` by whether the agent's binary resolves on the daemon's own
host, and the NixOS host has neither binary. atc refuses a spawn for a missing binary only on a
target that runs the agent on the daemon's host. The `geoffcloud` target runs the agent from the
agent image inside an imp, so the fields that decide a spawn there are `spawnTargets`, which lists
`geoffcloud`, and `capabilities.spawn`, which is `true`.

## Run the smoke

You need a gateway client whose principal the cloud daemon's config grants the `geoffcloud` target,
with the atc MCP tools.

1. Call `atc_spawn_options_get`.

   Expect `daemons.geoffcloud` to list `claude` with `spawnTargets: ["geoffcloud"]` and
   `capabilities.spawn: true`, target `geoffcloud` with `available: true`, and no `targetErrors`.

2. Call `atc_session_spawn` with these arguments:

   ```json
   {
     "daemon": "geoffcloud",
     "target": "geoffcloud",
     "agent": "claude",
     "name": "harness-smoke",
     "workspace": { "kind": "git", "url": "https://github.com/zgeoff/coderabbit", "ref": "main" },
     "trustClonedWorkspace": true,
     "prompt": "Write smoke-ok to smoke.txt, run cat smoke.txt, then run gh api user --jq .login."
   }
   ```

   Expect a session entry whose `cwd` is a folder under `/root/.local/share/atc/workspaces/`.

3. List the harness imps:

   ```bash
   ssh root@geoffcloud docker exec imp-host impz ls < /dev/null | grep harness-
   ```

   Expect one new imp on the image that the `geoffcloud` target names in
   `nixos/hosts/geoffcloud/configuration.nix`. atc names it `harness-` plus the session ID.

4. Check which atc runs the session's hooks:

   ```bash
   ssh root@geoffcloud journalctl -u atc-daemon --since -10min | grep 'runs hooks through'
   ```

   Expect the image's atc at `/usr/local/bin/atc`, at the daemon's atc version.

5. Call `atc_transcript_read` on the session.

   Expect `smoke-ok` from `cat` and a GitHub login from `gh`. If the transcript stops at a
   tool-permission prompt, read it with `atc_terminal_read` and answer it with
   `atc_terminal_choose`.

6. Call `atc_session_forget` with the session's ID and `"stop": true`.

   Forgetting a session on an imp destroys the imp, so this first call changes nothing. Expect a
   `confirmToken`, which is valid for 60 seconds. atc refuses a live session without `stop: true`.

7. Call `atc_session_forget` again within those 60 seconds, with the session's ID, `"stop": true`
   and the `confirmToken`.

   Expect `{ "forgotten": true, "destroyed": true }`. A refusal with `confirm_token_invalid` means
   the token expired or was spent, so start again at step 6.

8. Run the command from step 3 again.

   Expect the smoke imp to be gone.

## When the spawn fails

- The refusal `trustClonedWorkspace requires a workspace source` means the call left out
  `workspace`. Add the git source from step 2.
- A refusal with the code `auth_target_unsupported` that names a settings file means the
  repository's Claude settings would override the broker's sign-in. Use a repository without those
  settings.
- A session that shows the folder-trust dialog means the call left out `trustClonedWorkspace` or set
  it to `false`. Forget the session and spawn again with it set to `true`.
