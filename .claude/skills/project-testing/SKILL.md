---
name: project-testing
description:
  cloud's own testing rules on top of the shared testing skill — where each suite runs, the infra
  test utils (faker factories, the stub Pulumi Config, Outputs by reference), the health-check
  worker's MSW boundary, the Go provider's stub Onidel API and injected sleep, the shell suites'
  case runner and stand-ins, the NixOS checks and restore rehearsals, and the rule that no test
  reaches a real host. Load together with the testing skill when designing, writing, or reviewing
  cloud tests.
---

# cloud testing

This skill adds cloud's harnesses and stricter rules to the shared [testing](../testing/SKILL.md)
skill. It never relaxes a shared rule: where a suite in Go, shell or Nix cannot meet a shared rule
as written, the exception is decided in the shared skill, not here.

SKILL.md holds the suites, the host-safety rule, and the TypeScript and shell harnesses. The Go
provider and the NixOS checks each have a reference.

## Key rules

- [Suites and where they run](#suites-and-where-they-run): CI calls a root package script, the
  `nixos` job never runs on a person's PR, and every case is hermetic.
- [No test reaches a real host](#no-test-reaches-a-real-host): fail-closed stand-ins for every
  remote tool, handing off to the real one only on loopback.
- [infra (TypeScript)](#infra-typescript): units are pure builders and validators, tested with full
  factories, the stub Config, and Outputs by reference.
- [Operator scripts (TypeScript)](#operator-scripts-typescript): every subprocess goes through an
  injected `Runner`, and an unexpected call exits 97.
- [Shell suites](#shell-suites): each shared rule has a shell form, and each stand-in lives in
  `test-support/shell/` with its own test.

## References

- [provider-go.md](./references/provider-go.md): writing or reviewing a Go test in `provider/`, or
  using the stub Onidel API and the stub sleeps.
- [nixos-checks.md](./references/nixos-checks.md): writing or reviewing a NixOS check or a restore
  rehearsal under `nixos/checks/`.

## Suites and where they run

| Suite                                              | Command                             | Runs in CI                                |
| -------------------------------------------------- | ----------------------------------- | ----------------------------------------- |
| TypeScript unit tests in `infra/` and `scripts/`   | `bun run test`                      | `CI` → `ci`                               |
| The health-check Worker's tests                    | `bun run test:health-check`         | `CI` → `ci`                               |
| Go tests in `provider/`                            | `bun run provider:check`            | `CI` → `ci`, if `provider/` changed       |
| Shell suites and `test-support/shell/` tests       | `bun run test:scripts`              | `CI` → `ci`, unless only Markdown changed |
| A probe and its alert rule in their real engines (Docker) | `bun run test:alert-rules` | `CI` → `ci` |
| Gateway image, backup and restore journey (Docker) | `bun run test:atc-gateway-fixture`  | `atc-gateway images` → `fixture`          |
| nixie's backup script in its pinned image (Docker) | `bun run test:nixie-backup-fixture` | `nixie backup` → `fixture`                |
| The agent image's gitleaks allowlist (Docker)      | `bun run test:agent-image`          | `agent image` → `check`                   |
| NixOS checks and the restore rehearsals (KVM)      | `bun run test:nixos [check…]`       | `NixOS checks` → `nixos`                  |

- CI calls a root [`package.json`](../../../package.json) script, never a suite file directly.
- A new shell suite needs no list entry:
  [`run-shell-suites.sh`](../../../scripts/run-shell-suites.sh) runs every `test-*.sh` that git
  lists. A suite that needs Docker carries its group in a `# shell-suite: <group>` line of its
  header comment, so only its fixture's run picks it up. Each group runs from the root script for
  its fixture; [`run-fixture-tests.sh`](../../../images/atc-gateway/run-fixture-tests.sh) runs
  `atc-gateway-fixture` inside
  [`with-fixture-images.sh`](../../../test-support/shell/with-fixture-images.sh), and
  `fixture-images`, which tests that wrapper, from outside it.
- The `nixos` job gates the host switch, not the merge: it runs nightly and on a dispatch on main,
  and on an app's pull request that changes `nixos/`. A person's pull request never runs it, so run
  `bun run test:nixos` yourself, or dispatch the workflow on your branch, when a change can break a
  check. [`switch-geoffcloud.sh`](../../../scripts/switch-geoffcloud.sh) refuses a commit that no
  green run on main covers. [`needs-nixos-checks.sh`](../../../scripts/needs-nixos-checks.sh) lists
  the inputs of the checks, and a run stops covering later commits once one of them changes. A new
  input of the checks extends that list.
- Every test case is hermetic: no case reaches a real host, the tailnet, 1Password, Onidel,
  Cloudflare, the Pulumi state or the internet. The image and flake builds that run before the cases
  fetch only pinned inputs. `bun run drift` is a read-only check of a refactor, never part of a
  test.

## No test reaches a real host

This rule is stricter than the shared skill, because the tests here drive scripts that operate the
live host.

- Nothing in a test, a stand-in or a check runs `ssh`, `scp`, `sftp`, `rsync` or `tailscale` against
  a destination that is not loopback. OpenSSH reads the user's config from the passwd home, not
  `$HOME`, so a test-looking `ssh root@geoffcloud` reaches the real host.
- A shell suite whose script can call one of those tools writes a fail-closed stand-in for each of
  them in `$tree/bin`, and `setup_test` calls
  [`require_remote_tool_stubs`](../../../test-support/shell/require-remote-tool-stubs.sh) before the
  act, so a missing stand-in fails the case instead of falling back to `/usr/bin`.
- A stand-in hands a call to the real tool only for a loopback destination: ssh for
  `ssh://<user>@127.0.0.1:<port>` with `-F /dev/null` and no option after the destination; docker
  for a `unix://` socket that normalises to a path inside the case tree. The real binary comes from
  a fixed system path, resolved when the stand-in is created.
- A failure that real state can produce comes from real state on loopback: a dead port
  (`127.0.0.1:1`), a missing socket, a directory without write permission.
- A case whose act meets a mode that denies a write, a read or a search runs that act through
  [`run_with_file_modes`](../../../test-support/shell/run-with-file-modes.sh). Root passes such a
  mode, and a cloud imp runs its sessions as root, so without the helper the denial never happens
  there and the case fails.
- A DNS lookup (`getent hosts`) and a curl to a URL that is not loopback get stand-ins too. A real
  `getent` in a stand-in's own test reads the hosts file only (`-s files`).
- The real `gh` runs only with `GH_TELEMETRY=0 DO_NOT_TRACK=1 GH_NO_UPDATE_NOTIFIER=1`, in a case
  and in the fixture builds alike, because gh otherwise sends telemetry and checks for updates.
- A stand-in that speaks TLS hands its certificate to the client through the case's environment
  (`SSL_CERT_FILE`, with `SSL_CERT_DIR` set to an empty case directory), never through a trust store
  outside the case.

## infra (TypeScript)

`infra/` is in the pure regime: every unit under test is a builder or a validator that returns a
value. Resource-creating modules stay thin, and their logic lives in an exported `build*`,
`require*`, `find*` or `to*` function in its own file, which the test calls directly. The
health-check worker in `workers/health-check/` is HTTP-mocked.

- Each package keeps its preload in its own Bun config, and Bun reads only the one in the directory
  it runs from. A comment in each lists what its preload loads:
  [the root one](../../../bunfig.toml), for `bun run test`, [infra's](../../../infra/bunfig.toml),
  and [the health-check worker's](../../../workers/health-check/bunfig.toml), which never loads
  infra's preload.
- Beside the preload, [`infra/test-utils/`](../../../infra/test-utils/) holds the shared test utils,
  each with its own test file:
  - `buildMock<Type>` factories fill every field: faker values for arbitrary fields, a fixed value
    for constrained ones. A test passes `undefined` for a field whose absence it tests, and passes
    as an override every field its assertions depend on.
  - [`buildStubConfig`](../../../infra/test-utils/build-stub-config.ts) stands in for Pulumi's
    `Config`: `get` returns the raw string, `getBoolean` reads `true` and `false`, and `getObject`
    parses it, throwing the `RunError` the real `Config` throws for any other value. Only `index.ts`
    builds `Config` and reads the env, and a lint rule bans both elsewhere; the inputs group
    ([`infra/inputs/`](../../../infra/inputs/)) takes them as arguments, so a test never touches
    `process.env` or the Pulumi runtime.
  - [`resolveOutput`](../../../infra/test-utils/resolve-output.ts) reads an `Output`'s value. Assert
    secrecy with `isSecret`, separately from the value.
- The health-check worker's logic is tested through
  [`makeScheduledHandler`](../../../workers/health-check/make-scheduled-handler.ts): each test
  passes it a recording destination and asserts every logged change of state through it, never by
  replacing the global console. [`index.test.ts`](../../../workers/health-check/index.test.ts)
  checks the module Workers loads: its default export's `scheduled`, wired to `console`.
  [`buildStubR2Bucket`](../../../workers/health-check/test-utils/build-stub-r2-bucket.ts) is an
  in-memory R2 bucket. It implements `Pick<R2Bucket, 'get' | 'put'>` from
  `@cloudflare/workers-types` with R2's full object shapes, and rejects options and non-string
  values instead of modelling them. Its HTTP boundary is MSW handlers in
  [`workers/health-check/mocks/`](../../../workers/health-check/mocks/) over two in-memory stores:
  the probe targets' statuses and the alerts sent. The server runs with
  `onUnhandledRequest: 'error'`, and the preload also fails the test on any `request:unhandled`
  event, because the worker turns a failed probe into a status instead of throwing. A dead target is
  a per-test `passthrough()` to `127.0.0.1:1`, so the connection really fails.
- Pass an `Output` input by reference (`output('…')`) and put the same object in the expected
  literal: `toStrictEqual` fails when a builder swaps or rebuilds it.
- A hand-written spec (alert rules, Helm values, a Deployment spec, the tailnet policy) is asserted
  whole with `toStrictEqual` against a literal, never an inline snapshot.
- `expect.stringMatching` and `expect.any` return `any`, which the lint rule `no-unsafe-assignment`
  refuses inside a literal. Use a typed jest-extended matcher, such as `expect.toBeFunction()` or
  `expect.toBeValidDate()`, and where none fits, a typed `expect.toSatisfy`: a regex
  (`(value: string) => /…/u.test(value)`) or an `instanceof` check
  (`(value: unknown) => value instanceof ArrayBuffer`).

## Operator scripts (TypeScript)

An operator script in `scripts/` runs every subprocess through an injected `Runner`, so a test hands
it [`buildStubRunner`](../../../scripts/test-utils/build-stub-runner.ts) instead of
[`runProcess`](../../../scripts/run-process.ts). The stub runner records each call's argv, stdin and
options, and passes the call to its handlers in turn. A call that no handler answers exits 97 with
`unexpected: <argv as JSON>` on stderr, so a call the test did not expect fails closed and never
reaches a real tool.

- Each remote tool gets a `build-stub-<tool>.ts` handler in
  [`scripts/test-utils/`](../../../scripts/test-utils/) that answers as the real tool does, with its
  exit codes and messages, and cites its source in a comment. An ssh handler answers only its
  scenario's destination and runs nothing.
- A local tool that touches only the case's own files, such as git, tar or bash, runs for real
  through [`buildRealProgramHandler`](../../../scripts/test-utils/build-real-program-handler.ts).
  Git runs with the environment
  [`createGitOrigin`](../../../scripts/test-utils/create-git-origin.ts) returns, so the user's
  global and system config never reach a case.
- A script for the host lives in `scripts/host/` and travels on ssh's stdin. Its test runs it with
  real bash against loopback stand-ins, such as
  [`startStubImpd`](../../../scripts/test-utils/start-stub-impd.ts), beside the TypeScript that
  sends it.
- A script takes the time through a `now` function, and a test passes a fixed `Date`.
- A test asserts that no secret appears in any recorded argv, and that each secret reaches its call
  on stdin.

## Shell suites

`scripts/test-<script>.sh` tests `scripts/<script>.sh`. A test of a deploy artifact sits beside it,
as [`test-atc-gateway-image.sh`](../../../images/atc-gateway/test-atc-gateway-image.sh) does, and a
journey sits in `e2e/`, one file per journey. Each shared rule takes its shell form:

| Shared rule                  | Shell form                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test('it …')`               | a function `it_<words>`; its title is the name with spaces; `CASE='<part of a title>'` runs the matching cases                                                                                                                                                                                                                                                                                                                                                                              |
| `#<unit> <behaviour>`        | `it <unit> <behaviour>` in a file that tests several units, here and in the NixOS checks; the runners keep "it" as the first word, and Bun tests keep the shared `#<unit>` form                                                                                                                                                                                                                                                                                                             |
| The runner                   | [`run_cases`](../../../test-support/shell/run-cases.sh): each case in its own errexit subshell, `ok`/`FAIL` per case, exit 1 on any failure or when no case ran                                                                                                                                                                                                                                                                                                                             |
| `setupTest()`                | one `setup_test` per suite: a fresh `mktemp -d` tree and the stand-ins every case needs, with no scenario data; its config chooses which stand-ins to wire                                                                                                                                                                                                                                                                                                                                  |
| Dispose and `onTestFinished` | one `trap '…' EXIT` per case, because bash keeps one EXIT trap: on the line after `mktemp -d`, before `setup_test` acquires containers or processes, with each step safe when its resource was never reached; in a trap with more than one step, every step ends `\|\| true`; a variable a step reads is global, since a `local` is gone when the trap runs                                                                                                                                 |
| Every test stands alone      | the script under test runs under `env -i` with an explicit `PATH`, `HOME` and `TMPDIR` inside the case tree; git with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`; each suite starts with `umask 022`                                                                                                                                                                                                                                                                         |
| `toStrictEqual`              | the whole stdout, stderr and stand-in call log compared with `diff` against a heredoc, or the `assert_*` helpers in [`test-support/shell/`](../../../test-support/shell/); mask only a temp path, a generated id, or a measurement that changes between runs (a wall-clock time, a duration, a size, a memory or CPU reading), never the value under test                                                                                                                                   |
| Exact errors                 | the exact exit code, never "non-zero", plus the exact stderr                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Polling `waitFor`            | `wait_for <seconds> <what> <command…>`, from [`wait-for.sh`](../../../test-support/shell/wait-for.sh)                                                                                                                                                                                                                                                                                                                                                                                       |
| Injected time                | `WAIT_FOR_CLOCK` and `WAIT_FOR_SLEEP`, stepped by [`create_stub_clock`](../../../test-support/shell/create-stub-clock.sh), so a timeout case counts pauses instead of waiting out seconds; the defaults are covered by a polled command that advances bash's `SECONDS` and by the clock's pause first on `PATH` as `sleep`; a case that only bounds the stamp reads the clock before and after the act and checks it with [`assert_between`](../../../test-support/shell/assert-between.sh) |
| Reproducible data            | random values derive from `SEED`, which the run prints                                                                                                                                                                                                                                                                                                                                                                                                                                      |

- A case checks its exit status exactly, with
  `[ "$status" = N ] || { echo "exit $status, want N" >&2; exit 1; }` or `assert_equals`; both are
  exact.
- Each git repository that a test creates, a bare origin included, sets `maintenance.auto false`
  in its own config, in a shell suite and a TypeScript test alike. Otherwise a commit, a fetch or a
  push starts git's detached maintenance, whose repack can still write into the repository while
  the case's cleanup removes it, and the case fails at random. A push to a local origin drops the
  `GIT_CONFIG_*` variables, so a setting passed in the environment never reaches the origin.
- A stand-in lives in `test-support/shell/` with its own `test-<file>.sh`, never inline in a suite:
  `create-stub-<thing>.sh` writes an executable to disk, and `start-stub-<thing>.sh` runs a process.
- A stand-in that replaces a tool logs its argv as one JSON line, matches the real tool's exit codes
  and messages, and ends with `*) echo "unexpected: $*" >&2; exit 97`. Where the real tool's output
  differs between the versions CI and a developer run, a comment records both versions and the test
  accepts each version's output only with its own exit code, through
  [`assert_one_of_outputs`](../../../test-support/shell/assert-one-of-outputs.sh), which binds each
  version's stdout, stderr and exit status together. A process stand-in records an unexpected
  request and answers it with a failure.
- A stand-in that wraps the real tool, such as
  [`create-stub-racing-git.sh`](../../../test-support/shell/create-stub-racing-git.sh), or that
  supplies a value rather than a tool, such as
  [`create-stub-clock.sh`](../../../test-support/shell/create-stub-clock.sh), states in its header
  what it changes, and its test pins that change.
- A stand-in checked against documentation rather than the real tool, such as
  [`create-stub-op.sh`](../../../test-support/shell/create-stub-op.sh), records the pages, the tool
  version and the check date in its header, and lists what the docs leave unsettled.
- An ssh stand-in that cannot run the remote command, because it needs root or a container, answers
  as the host would, and the case writes out the whole remote command as the expected argv. One that
  runs the command locally runs it under `env -i` from the case's host directory, forwarding only
  the host's environment file and the host stand-ins' own settings.
- A guard's tests pass it a search path the case owns, so its expected text never depends on the
  host.
- A producer whose output a case compares writes to a file under errexit first, so a failing
  producer fails the case instead of producing an empty match.
- Every other helper in `test-support/shell/` exports one public function, named for its file, and
  has its own `test-<helper>.sh` that `test:scripts` runs, or `test:atc-gateway-fixture` when it
  needs Docker.
- The Docker suites run under
  [`with-fixture-images.sh`](../../../test-support/shell/with-fixture-images.sh), which builds the
  images once per run under tags that carry a random run id and removes them after. Every container
  and volume name carries that id, and each case's trap removes its containers before its volumes.
  The images run as production runs them: uid 65532, no capabilities, no privilege escalation.
