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

| Fact       | Where                                                                                                                                                                                                                                                                                                                          |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Lanes      | the `lanes` option of `zgeoff/max-test-timeout` in [`.oxlintrc.json`](../../../.oxlintrc.json); the `e2e/` folder, which `pathIgnorePatterns` in [`bunfig.toml`](../../../bunfig.toml) leaves out of the unit run                                                                                                              |
| Test utils | the `test-utils/` folder of the package, such as [`infra/test-utils/`](../../../infra/test-utils/) or [`scripts/test-utils/`](../../../scripts/test-utils/); [`test-support/shell/`](../../../test-support/shell/) for a shell suite; [`nixos/checks/test-utils/`](../../../nixos/checks/test-utils/) for a NixOS check |

## Departures

- Test a shell script with a `test-<name>.sh` suite beside it, which runs its cases through
  [`run_cases`](../../../test-support/shell/run-cases.sh). [Shell testing](../testing/references/shell.md)
  asks for a `<name>.test.ts` file instead. cloud keeps one shell harness, because the NixOS checks
  run `run_cases` and the `assert_*` helpers that
  [`build-shell-lib-source.nix`](../../../nixos/checks/test-utils/build-shell-lib-source.nix)
  selects inside their VMs. Test a script in `scripts/host/` from TypeScript, as
  [Operator scripts](#operator-scripts) describes.
- Assert a Go test with testify's `assert` and `require`.
  [Go assertions](../testing/references/go.md#assertions) asks for gotest.tools or go-cmp. Every
  provider test uses testify, and a second library would split the suite.

## Suites in CI

- Add a `test-*.sh` suite without a list entry.
  [`run-shell-suites.sh`](../../../scripts/run-shell-suites.sh) runs every `test-*.sh` that git
  tracks or sees as untracked.
- Leave the `# shell-suite: <group>` line out of a suite that needs no Docker, so that
  `bun run test:scripts` runs it. Give a Docker suite the group of the `test:*` script that runs it,
  such as `alert-rules` for `test:alert-rules`.
- When a suite starts to read a new file, add that file's path to the suite's gate in
  [`gates.yml`](../../../.github/gates.yml), if it has one. Otherwise CI skips the suite when only
  that file changes.
- Read the `NixOS checks` result on the pull request before you merge a change to a check's inputs.
  The workflow doesn't block the merge, but
  [`switch-geoffcloud.sh`](../../../scripts/switch-geoffcloud.sh) refuses to deploy a commit that no
  green run on main covers.
- Set `maintenance.auto false` in each git repository a test creates, a bare origin included, in any
  language. Git's background repack can write into the repository while the cleanup removes it.

## Real hosts

The scripts under test operate the live host, so a slip here changes production. Never let a case
reach a real host, the tailnet, 1Password, Onidel, Cloudflare, the Pulumi state or the internet.
Builds before the cases fetch only pinned inputs.

- Never run `ssh`, `scp`, `sftp`, `rsync` or `tailscale` against a destination that isn't loopback.
  OpenSSH reads the config in the passwd home, not `$HOME`, so `ssh root@geoffcloud` in a test
  reaches the real host.
- In a suite whose script can call any of those five, put a stand-in for all five in the case's
  `bin` folder, through
  [`create_stub_remote_tools`](../../../test-support/shell/create-stub-remote-tools.sh) for the ones
  no other stand-in covers. Then call
  [`require_remote_tool_stubs`](../../../test-support/shell/require-remote-tool-stubs.sh) in
  `setup_test`, which fails the case when a call would fall through to `/usr/bin`.
- Hand a call to the real tool only for a loopback destination. In each ssh stand-in, include the
  lines that [`print_ssh_pass_through`](../../../test-support/shell/print-ssh-pass-through.sh)
  prints. Hand docker only a `unix://` socket inside the case tree.
- Produce a failure from real state on loopback when real state can produce it, such as a dead port
  (`127.0.0.1:1`) or a missing socket.
- Run an act that a file mode should refuse through
  [`run_with_file_modes`](../../../test-support/shell/run-with-file-modes.sh). Root ignores file
  modes, and the imp agent sessions run as root.
- Stand in for `getent hosts` and for curl to a URL that isn't loopback. In the `getent` stand-in's
  own test, call the real `getent` with `-s files`.
- Run the real `gh` only with `GH_TELEMETRY=0 DO_NOT_TRACK=1 GH_NO_UPDATE_NOTIFIER=1`.
- Give a TLS stand-in's certificate to the client through `SSL_CERT_FILE`, with `SSL_CERT_DIR` set to
  an empty case folder.

## infra

- Put the logic of a module that creates resources in an exported `build*`, `require*`, `find*` or
  `to*` function in its own file, and test that function.
- Pass [`buildStubConfig`](../../../infra/test-utils/build-stub-config.ts) where the code takes a
  Pulumi `Config`. Only `index.ts` builds `Config` and reads the environment.
- Read an `Output` with [`resolveOutput`](../../../infra/test-utils/resolve-output.ts). Assert its
  secrecy in its own assertion, with Pulumi's `isSecret`.
- Pass an `Output` input by reference, with `output('…')`, and put the same object in the expected
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
- Use [`buildStubR2Bucket`](../../../workers/health-check/test-utils/build-stub-r2-bucket.ts) for the
  bucket.
- Seed probe targets and read sent alerts through the stores in
  [`mocks/`](../../../workers/health-check/mocks/). The preload in the worker's
  [`bunfig.toml`](../../../workers/health-check/bunfig.toml) fails a test on any request no MSW
  handler matches, because the worker turns a failed probe into a status.
- Make a dead target with a per-test MSW `passthrough()` to `127.0.0.1:1`.

## Operator scripts

These rules cover the TypeScript scripts in `scripts/`.

- Run every subprocess through the script's injected `Runner`. In a test, pass
  [`buildStubRunner`](../../../scripts/test-utils/build-stub-runner.ts), which exits 97 with
  `unexpected: <argv>` on any call that no stand-in handles.
- Answer a remote tool with a `build-stub-<tool>.ts` stand-in in `scripts/test-utils/`. Match the
  real tool's exit codes and messages, and cite the docs or code you took them from.
- Run a local tool that touches only the case's files, such as git or tar, through
  [`buildRealProgramHandler`](../../../scripts/test-utils/build-real-program-handler.ts). Run git
  with the environment that [`createGitOrigin`](../../../scripts/test-utils/create-git-origin.ts)
  returns.
- Test a script in `scripts/host/`, which travels on ssh's stdin, with real bash against loopback
  stand-ins, such as [`startStubImpd`](../../../scripts/test-utils/start-stub-impd.ts).
- Assert that no secret appears in any recorded argv, and that each secret reaches its call on
  stdin.

## Shell suites

- Name each case as a function `it_<words>`. Its title is the name with spaces for underscores, and
  `CASE='<part of a title>'` runs the matching cases.
- Write one `setup_test` per suite, which wires the stand-ins every case needs and holds no scenario
  data.
- Make each case's temporary folder with one
  [`create_case_tree`](../../../test-support/shell/create-case-tree.sh) call, and pass the case's
  cleanup to it. The call sets the case's one EXIT trap, so never set a second trap.
- Run the script under test with `env -i` and an explicit `PATH`, `HOME` and `TMPDIR` in the case
  tree. Start each suite with `umask 022`.
- Compare the whole stdout, the whole stderr and the stand-in call log, with `diff` against a
  heredoc or with the `assert_*` helpers. Check the exact exit code with
  [`assert_status`](../../../test-support/shell/assert-status.sh).
- Poll with `wait_for` from [`wait-for.sh`](../../../test-support/shell/wait-for.sh), and step time
  with [`create_stub_clock`](../../../test-support/shell/create-stub-clock.sh).
- In a suite that a NixOS check runs, source only the helpers that `build-shell-lib-source.nix`
  selects, so neither `create_case_tree` nor `assert_status`.

For stand-ins:

- Put each stand-in in `test-support/shell/` with its own `test-<file>.sh`, never inline in a suite.
  Name it `create-stub-<thing>.sh` when it writes an executable, and `start-stub-<thing>.sh` when it
  runs a process.
- Make a tool stand-in log its argv as one JSON line, match the real tool's exit codes and messages,
  and end with `*) echo "unexpected: $*" >&2; exit 97`. When the real output differs between CI's
  version and a developer's, check both through
  [`assert_one_of_outputs`](../../../test-support/shell/assert-one-of-outputs.sh).
- Answer gh only through [`create-stub-gh.sh`](../../../test-support/shell/create-stub-gh.sh). Write
  each response in the case, for the exact argv the script sends, and cite its source. Put a long
  body that several suites replay in [`gh-recordings/`](../../../test-support/shell/gh-recordings/).
- When you check a stand-in against docs instead of the real tool, as
  [`create-stub-op.sh`](../../../test-support/shell/create-stub-op.sh) is, record the pages, the tool
  version and the date in its header.
- When a `test:scripts` suite needs a tool that a developer's host may lack, check for it before
  `run_cases`. Print `skip` and exit 0, or exit 1 when `CI` is set. Never skip a Docker suite.
- Run a Docker suite under
  [`with-fixture-images.sh`](../../../test-support/shell/with-fixture-images.sh). Put `$FIXTURE_RUN`
  in every container and volume name, and remove the containers before the volumes. Run each image
  as production does: uid 65532, no capabilities, no privilege escalation.
