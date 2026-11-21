---
name: project-testing
description:
  'The test facts of the cloud repo, the testing rules it replaces, and its harnesses: the shell
  suites and their stand-ins, the stand-ins that keep tests off the real hosts, the infra and
  health-check test utils, and the stub runner of the TypeScript operator scripts. Load it beside
  testing before you write or review a test in cloud.'
metadata:
  kind: rule-set
---

# cloud testing

## References

- [provider-go.md](./references/provider-go.md): before you write or review a Go test in
  `provider/`.
- [nixos-checks.md](./references/nixos-checks.md): before you write or review a NixOS check or a
  restore rehearsal in `nixos/checks/`.

## Facts

| Fact          | Where                                                                                                                                                                                                                                                                                                                   |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Test commands | [`rig.config.ts`](../../../rig.config.ts) holds each test command's file suffix and per-test timeout. `bun run test:e2e` runs the journeys in `scripts/e2e/` through `rig e2e`, which builds each program that `rig.config.ts` declares first, and `bun run test` leaves them out                                                                                                                                   |
| Test utils    | the `src/test-utils/` folder of the package, such as [`infra/src/test-utils/`](../../../infra/src/test-utils/) or [`scripts/src/test-utils/`](../../../scripts/src/test-utils/); [`scripts/src/test-utils/shell/`](../../../scripts/src/test-utils/shell/) for a shell suite; [`nixos/checks/test-utils/`](../../../nixos/checks/test-utils/) for a NixOS check |

## Departures

- Test a shell script with a `<name>.bats` suite beside it, which
  [`run-bats.sh`](../../../scripts/run-bats.sh) runs. [Shell testing](../testing/references/shell.md)
  asks for a `<name>.test.ts` file instead. The suites share shell stand-ins, and the NixOS checks
  use bats too, so a TypeScript harness would give cloud a second one.
- Assert a Go test with testify's `assert` and `require`.
  [Go assertions](../testing/references/go.md#assertions) asks for gotest.tools or go-cmp. Every
  provider test uses testify, and a second library would split the suite.

## Suites in CI

- Add a suite by creating a `.bats` file. `run-bats.sh` runs every `.bats` file that git tracks or
  sees as untracked.
- Tag each suite on the line after its shebang with `# bats file_tags=suite:<group>`. Give a suite
  that needs no Docker the `scripts` group, which `bun run test:scripts` runs. Give a Docker suite
  the group of the `test:*` script that runs it, such as `alert-rules` for `test:alert-rules`.
  `run-bats.sh` skips a file with no tag.
- When a suite starts to read a new file, add that file's path to the suite's gate in
  [`gates.yml`](../../../.github/gates.yml), if it has one. A gate lists the paths whose change makes
  CI run a check. CI skips the suite when only an unlisted file changes.
- Read the `NixOS checks` result on the pull request before you merge a change to a check's inputs.
  The workflow doesn't block the merge, but
  [`switch-geoffcloud.sh`](../../../scripts/switch-geoffcloud.sh) refuses to deploy a commit unless a
  green run on main covers it.
- Run `git config maintenance.auto false` in each git repository a test creates, a bare origin
  included, in any language. Git's background repack can write into the repository while the cleanup removes it.

## Real hosts

The scripts under test operate the live host, so a slip here changes production. Never let a case
reach a real host, the tailnet, 1Password, Onidel, Cloudflare, the Pulumi state or the internet.
When a suite needs a download, fetch it in a build step before the cases, and fetch pinned inputs
only.

- Never run `ssh`, `scp`, `sftp`, `rsync` or `tailscale` against a destination that isn't loopback.
  OpenSSH reads the config in the passwd home, not `$HOME`, so `ssh root@geoffcloud` in a test
  reaches the real host.
- In a suite whose script can call any of those five, put a stand-in for all five in the case's
  `bin` folder, through
  [`create_stub_remote_tools`](../../../scripts/src/test-utils/shell/create-stub-remote-tools.sh) for the ones
  no other stand-in covers. Then call
  [`require_remote_tool_stubs`](../../../scripts/src/test-utils/shell/require-remote-tool-stubs.sh) in
  `setup_test`, which fails the case when a call would fall through to `/usr/bin`.
- Hand a call to the real tool only for a loopback destination. In each ssh stand-in, include the
  lines that [`print_ssh_pass_through`](../../../scripts/src/test-utils/shell/print-ssh-pass-through.sh)
  prints. Hand docker only a `unix://` socket inside the case tree, `$BATS_TEST_TMPDIR`.
- Produce a failure from real state on loopback when real state can produce it, such as a dead port
  (`127.0.0.1:1`) or a missing socket.
- Run a read or write that a file mode should refuse through
  [`run_with_file_modes`](../../../scripts/src/test-utils/shell/run-with-file-modes.sh). Root ignores file
  modes, and the imp agent sessions run as root.
- Stand in for `getent hosts` and for curl to a URL that isn't loopback. In the `getent` stand-in's
  own test, call the real `getent` with `-s files`, which reads the hosts file and never asks DNS.
- Run the real `gh` only with `GH_TELEMETRY=0 DO_NOT_TRACK=1 GH_NO_UPDATE_NOTIFIER=1`, so it sends
  no telemetry and makes no update check.
- Give a TLS stand-in's certificate to the client through `SSL_CERT_FILE`, with `SSL_CERT_DIR` set to
  an empty case folder, so the client trusts that certificate and no system one.

## infra

- Put the logic of a module that creates resources in an exported `build*`, `require*`, `find*` or
  `to*` function in its own file, and test that function.
- Pass [`buildStubConfig`](../../../infra/src/test-utils/build-stub-config.ts) where the code takes a
  Pulumi `Config`. Only `index.ts` builds `Config` and reads the environment.
- Read an `Output` with [`resolveOutput`](../../../infra/src/test-utils/resolve-output.ts). Assert its
  secrecy in its own assertion, with Pulumi's `isSecret`.
- Pass an `Output` input by reference, with `output('<value>')`, and put the same object in the expected
  literal, so `toStrictEqual` fails when a builder rebuilds it.
- Use a typed jest-extended matcher, such as `expect.toBeFunction()`, or a typed `expect.toSatisfy`,
  in place of `expect.any` or `expect.stringMatching`. Those two return `any`, which the lint rule
  `no-unsafe-assignment` refuses inside a literal.
- Run `pulumi preview` in a test only as
  [`create-cluster-provider.test.ts`](../../../infra/cluster/create-cluster-provider.test.ts) does:
  a fixture program, a local state backend and a Kubernetes provider that renders to files.

## The health-check worker

- Test the worker through
  [`makeScheduledHandler`](../../../workers/health-check/make-scheduled-handler.ts). Pass it an
  object whose `log` records each message, and never replace the global console.
- Use [`buildStubR2Bucket`](../../../workers/health-check/src/test-utils/build-stub-r2-bucket.ts) for the
  bucket.
- Seed probe targets and read sent alerts through the stores in
  [`src/test-utils/`](../../../workers/health-check/src/test-utils/). The preload in the worker's
  [`bunfig.toml`](../../../workers/health-check/bunfig.toml) fails a test on any request that
  matches no MSW handler. The worker turns a failed probe into a "down" status, so without that preload an
  unmatched request would pass as a probe result.
- Make a dead target with a per-test MSW `passthrough()` to `127.0.0.1:1`.

## Operator scripts

These rules cover the TypeScript scripts in `scripts/`, and the TypeScript tests of the bash scripts
in `scripts/host/`.

- Run every subprocess through the script's injected `Runner`. In a test, pass
  [`buildStubRunner`](../../../scripts/src/test-utils/build-stub-runner.ts), which exits 97 with
  `unexpected: <argv>` on any call that no stand-in handles.
- Stand in for a remote tool with a `build-stub-<tool>.ts` file in `scripts/src/test-utils/`. Match the
  real tool's exit codes and messages, and cite the docs or code you took them from.
- Run a local tool that touches only the case's files, such as git or tar, through
  [`buildRealProgramHandler`](../../../scripts/src/test-utils/build-real-program-handler.ts). Run git
  with the environment that [`createGitOrigin`](../../../scripts/src/test-utils/create-git-origin.ts)
  returns.
- Test a script in `scripts/host/`, which travels on ssh's stdin, with real bash against loopback
  stand-ins, such as [`startStubImpd`](../../../scripts/src/test-utils/start-stub-impd.ts).
- Assert that no secret appears in any recorded argv, and that each secret reaches its call on
  stdin.

## Shell suites

- Name each case `@test "it <words>"`. Run the cases whose title holds a phrase with
  `CASE='<phrase>' bash scripts/run-bats.sh <group>`.
- Load [`setup.bash`](../../../scripts/src/test-utils/bats/setup.bash) from both `setup_file` and
  `setup`, and call `stop_timeout_watchdog` first in every `teardown`, as `setup.bash` explains.
- In `setup`, load the stand-in scripts the suite uses, set `umask 022`, and set
  `tree="$BATS_TEST_TMPDIR"`, the case tree.
- Write one `setup_test` per suite, which each case calls first. It wires the stand-ins every case
  needs and holds no scenario data.
- Run the script under test with `env -i` and a `PATH`, `HOME` and `TMPDIR` in the case tree, with
  `$tree/bin`, the case's `bin` folder, first on `PATH`.
- Compare the whole stdout, stderr and stand-in call log. Use `run -<status> --separate-stderr`
  with `assert_output` and `assert_stderr`, and `diff` the call log against a heredoc. To pin exact
  bytes, such as a trailing newline that `run` drops, write the output to a file and `cmp` it.
- Poll with `wait_for` from [`wait-for.sh`](../../../scripts/src/test-utils/shell/wait-for.sh), and step time
  with [`create_stub_clock`](../../../scripts/src/test-utils/shell/create-stub-clock.sh).

A NixOS check's cases can call only `wait_for` of the shell helpers, because
[`build-shell-lib-source.nix`](../../../nixos/checks/test-utils/build-shell-lib-source.nix) copies
only `wait-for.sh` into the checks.

## Shell stand-ins

- Put each script that writes or starts a stand-in in `scripts/src/test-utils/shell/`, with its own
  `<file>.bats`, never inline in a suite.
  Name it `create-stub-<thing>.sh` when it writes an executable, and `start-stub-<thing>.sh` when it
  runs a process.
- Make a tool stand-in log its argv as one JSON line, match the real tool's exit codes and messages,
  and end with `*) echo "unexpected: $*" >&2; exit 97`. When the real output differs between CI's
  version and a developer's, pass the case when the output matches either version exactly.
- Stand in for gh only through [`create-stub-gh.sh`](../../../scripts/src/test-utils/shell/create-stub-gh.sh). Write
  each response in the case, for the exact argv the script sends, and cite its source. Put a long
  body that several suites replay in [`gh-recordings/`](../../../scripts/src/test-utils/shell/gh-recordings/).
- When you check a stand-in against docs instead of the real tool, as
  [`create-stub-op.sh`](../../../scripts/src/test-utils/shell/create-stub-op.sh) is, record the pages, the tool
  version and the date in its header.
- When a `test:scripts` suite needs a tool that a developer's host may lack, check for it in
  `setup`. Call `skip` when it is missing, and fail when `CI` is set. Never skip a Docker suite.
- Run a Docker suite under
  [`with-fixture-images.sh`](../../../scripts/src/test-utils/shell/with-fixture-images.sh). Put `$FIXTURE_RUN`
  in every container and volume name, and remove the containers before the volumes. Run each image
  with the user and security settings that production gives it.
