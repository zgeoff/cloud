---
name: project-testing
description:
  'The test facts of the cloud repo, the testing rules it replaces, and its harnesses: the shell
  suites and their stand-ins, the rule that no test reaches a real host, the infra and health-check
  test utils, and the operator scripts'' stub runner. Load it beside testing before you write or
  review a test in cloud.'
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
| Lanes      | the `lanes` option of `zgeoff/max-test-timeout` in [`.oxlintrc.json`](../../../.oxlintrc.json)                                                                                                                                                                                                                                 |
| Test utils | the `test-utils/` folder of the package, such as [`infra/test-utils/`](../../../infra/test-utils/) or [`scripts/test-utils/`](../../../scripts/test-utils/); [`test-support/shell/`](../../../test-support/shell/) for a shell suite; [`nixos/checks/test-utils/`](../../../nixos/checks/test-utils/) for a NixOS check |

## Departures

- Test a shell script with a `test-<script>.sh` suite beside it that runs its cases through
  [`run_cases`](../../../test-support/shell/run-cases.sh), never a `<script>.test.ts` file, which
  [shell testing](../testing/references/shell.md) asks for. The NixOS checks run the same runner and
  `assert_*` helpers inside their VMs, as
  [`build-shell-lib-source.nix`](../../../nixos/checks/test-utils/build-shell-lib-source.nix)
  selects them, so one shell harness serves the host scripts and the checks. A script in
  `scripts/host/` is the exception: test it from TypeScript, as
  [Operator scripts](#operator-scripts) says.
- Assert a Go test with testify's `assert` and `require`, never gotest.tools or go-cmp, which
  [Go assertions](../testing/references/go.md#assertions) asks for. Every provider test uses
  testify, so a second library would split the suite.

## CI and the suites

- Add a test file or a `test-*.sh` suite without a list entry:
  [`run-shell-suites.sh`](../../../scripts/run-shell-suites.sh) runs every `test-*.sh` that git
  lists. Put a suite that needs Docker in its fixture's group with a `# shell-suite: <group>` line in
  its header comment.
- When you add an input to a suite that CI gates, add its path to the suite's gate in
  [`gates.yml`](../../../.github/gates.yml).
- Never count on the `NixOS checks` workflow to gate a merge. It gates the host switch:
  [`switch-geoffcloud.sh`](../../../scripts/switch-geoffcloud.sh) refuses a commit that no green run
  on main covers.
- Never let a case reach a real host, the tailnet, 1Password, Onidel, Cloudflare, the Pulumi state or
  the internet. Image and flake builds before the cases fetch only pinned inputs.

## No test reaches a real host

The scripts under test operate the live host, so a slip here changes production.

- Never run `ssh`, `scp`, `sftp`, `rsync` or `tailscale` against a destination that isn't loopback,
  in a test, a stand-in or a check. OpenSSH reads the user's config from the passwd home, not
  `$HOME`, so `ssh root@geoffcloud` in a test reaches the real host.
- When the script under test can call one of those tools, write a fail-closed stand-in for each in
  `$tree/bin`, and call
  [`require_remote_tool_stubs`](../../../test-support/shell/require-remote-tool-stubs.sh) in
  `setup_test`, so a missing stand-in fails the case instead of falling back to `/usr/bin`.
- Hand a call to the real tool only for a loopback destination: ssh to
  `ssh://<user>@127.0.0.1:<port>` with `-F /dev/null`, docker to a `unix://` socket inside the case
  tree. Write the ssh guard into each ssh stand-in from
  [`print_ssh_pass_through`](../../../test-support/shell/print-ssh-pass-through.sh).
- Produce a failure from real state on loopback when real state can produce it: a dead port
  (`127.0.0.1:1`), a missing socket, a directory without write permission.
- Run an act that meets a denying file mode through
  [`run_with_file_modes`](../../../test-support/shell/run-with-file-modes.sh). imp runs its sessions
  as root, and root passes the mode without it.
- Stand in for `getent hosts` and for curl to any URL that isn't loopback. In a stand-in's own test,
  call the real `getent` with `-s files`.
- Run the real `gh` only with `GH_TELEMETRY=0 DO_NOT_TRACK=1 GH_NO_UPDATE_NOTIFIER=1`, in a case and
  in a fixture build.
- Give a TLS stand-in's certificate to the client through `SSL_CERT_FILE`, with `SSL_CERT_DIR` set to
  an empty case directory, never through a trust store outside the case.

## infra

- Put the logic of a module that creates resources in an exported `build*`, `require*`, `find*` or
  `to*` function in its own file, and test that function. Keep the module thin.
- Read Pulumi config only through [`buildStubConfig`](../../../infra/test-utils/build-stub-config.ts)
  in a test. Only `index.ts` builds `Config` and reads the environment, and a lint rule bans both
  elsewhere.
- Read an `Output` with [`resolveOutput`](../../../infra/test-utils/resolve-output.ts), and assert
  its secrecy with `isSecret`, apart from its value.
- Pass an `Output` input by reference, with `output('…')`, and put the same object in the expected
  literal, so `toStrictEqual` fails when a builder rebuilds it.
- Use a typed jest-extended matcher, such as `expect.toBeFunction()`, or a typed `expect.toSatisfy`,
  in place of `expect.any` or `expect.stringMatching`. Both return `any`, which
  `no-unsafe-assignment` refuses inside a literal.
- Run `pulumi preview` in a test only as
  [`create-cluster-provider.test.ts`](../../../infra/cluster/create-cluster-provider.test.ts) does: a
  fixture program, a local state backend and a Kubernetes provider that renders to files.

## The health-check worker

- Test the worker through
  [`makeScheduledHandler`](../../../workers/health-check/make-scheduled-handler.ts), with a
  recording destination for its log. Never replace the global console.
- Use [`buildStubR2Bucket`](../../../workers/health-check/test-utils/build-stub-r2-bucket.ts) for the
  bucket. It models only the `get` and `put` the worker makes.
- Seed probe targets and read sent alerts through the stores in
  [`mocks/`](../../../workers/health-check/mocks/). The preload fails a test on any unhandled
  request, because the worker turns a failed probe into a status instead of throwing.
- Make a dead target with a per-test `passthrough()` to `127.0.0.1:1`, so the connection fails for
  real.

## Operator scripts

- Run every subprocess of a script in `scripts/` through its injected `Runner`. In a test, pass
  [`buildStubRunner`](../../../scripts/test-utils/build-stub-runner.ts), which exits 97 with
  `unexpected: <argv>` on any call no handler answers.
- Answer a remote tool with a `build-stub-<tool>.ts` handler in `scripts/test-utils/` that matches
  the real tool's exit codes and messages, and cite its source in a comment.
- Run a local tool that touches only the case's files, such as git or tar, through
  [`buildRealProgramHandler`](../../../scripts/test-utils/build-real-program-handler.ts). Run git
  with the environment that [`createGitOrigin`](../../../scripts/test-utils/create-git-origin.ts)
  returns.
- Test a script in `scripts/host/`, which travels on ssh's stdin, with real bash against loopback
  stand-ins such as [`startStubImpd`](../../../scripts/test-utils/start-stub-impd.ts).
- Assert that no secret appears in any recorded argv, and that each secret reaches its call on
  stdin.

## Shell suites

Write each shared rule in its shell form:

- Name each case as a function `it_<words>`. `CASE='<part of a title>'` runs the matching cases.
- Write one `setup_test` per suite: a fresh `mktemp -d` tree and the stand-ins every case needs,
  with no scenario data. Make the tree and its EXIT trap with one
  [`create_case_tree`](../../../test-support/shell/create-case-tree.sh) call.
- Keep one `trap '…' EXIT` per case, since bash keeps one. End each step of a trap with more than one
  step in `|| true`, and make each step safe when its resource never came up.
- Run the script under test with `env -i` and an explicit `PATH`, `HOME` and `TMPDIR` in the case
  tree. Start each suite with `umask 022`.
- Compare the whole stdout, stderr and stand-in call log with `diff` against a heredoc, or with the
  `assert_*` helpers. Check the exact exit code with
  [`assert_status`](../../../test-support/shell/assert-status.sh).
- Poll with `wait_for` from [`wait-for.sh`](../../../test-support/shell/wait-for.sh), and step time
  with [`create_stub_clock`](../../../test-support/shell/create-stub-clock.sh). Derive random values
  from `SEED`.
- In a suite that the NixOS checks run, use neither `create_case_tree` nor `assert_status`. The
  checks see only the files `build-shell-lib-source.nix` selects.

For stand-ins and other helpers:

- Set `maintenance.auto false` in each git repository a test creates, a bare origin included, in a
  shell suite and a TypeScript test alike. Git's detached repack can write into the repository while
  cleanup removes it.
- Put each stand-in in `test-support/shell/` with its own `test-<file>.sh`, never inline in a suite.
  Name it `create-stub-<thing>.sh` when it writes an executable, and `start-stub-<thing>.sh` when it
  runs a process.
- Make a tool stand-in log its argv as one JSON line, match the real tool's exit codes and messages,
  and end with `*) echo "unexpected: $*" >&2; exit 97`. When the real output differs between CI's
  version and a developer's, check both through
  [`assert_one_of_outputs`](../../../test-support/shell/assert-one-of-outputs.sh).
- Answer gh only through [`create-stub-gh.sh`](../../../test-support/shell/create-stub-gh.sh), with
  responses the case records for the exact argv, each citing its source. Put a long body that
  several suites replay in [`gh-recordings/`](../../../test-support/shell/gh-recordings/).
- When a stand-in is checked against docs instead of the real tool, as
  [`create-stub-op.sh`](../../../test-support/shell/create-stub-op.sh) is, record the pages, the tool
  version and the check date in its header.
- When a `test:scripts` suite needs a tool that a developer's host may lack, check for it before
  `run_cases`: print `skip` and exit 0, or exit 1 when `CI` is set. Never skip a Docker suite.
- Run a Docker suite under
  [`with-fixture-images.sh`](../../../test-support/shell/with-fixture-images.sh). Put its run id in
  every container and volume name, and remove the containers before the volumes. Run each image as
  production does: uid 65532, no capabilities, no privilege escalation.
