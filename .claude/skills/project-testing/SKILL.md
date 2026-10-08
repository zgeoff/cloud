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

This skill adds cloud's harnesses and stricter rules to the shared `testing` skill. It never relaxes
a shared rule: where a suite in Go, shell or Nix cannot meet a shared rule as written, the exception
is decided in the shared skill, not here.

## Suites and where they run

| Suite                                              | Command                            | Runs in CI                       |
| -------------------------------------------------- | ---------------------------------- | -------------------------------- |
| TypeScript unit tests in `infra/` and `workers/`   | `bun run test`                     | `CI` → `checks`                  |
| Go tests in `provider/`                            | `bun run provider:check`           | `CI` → `provider`                |
| Shell suites and `scripts/test-lib/` tests         | `bun run test:scripts`             | `CI` → `checks`                  |
| Gateway image, backup and restore journey (Docker) | `bun run test:atc-gateway-fixture` | `atc-gateway images` → `fixture` |
| NixOS checks and the restore rehearsals (KVM)      | `bun run test:nixos [check…]`      | `NixOS checks` → `nixos`         |

- A new suite gets a root `package.json` script, and CI calls that script, never the file directly.
- The `nixos` job reports on every pull request and push to main, and the ruleset requires it.
  `bun run ci:needs-nixos-checks <base> <head>` decides whether it boots the checks: any change
  under `nixos/` or `scripts/`, to `package.json`, `.bun-version`, `.gitignore` or the workflow, a
  new branch or a rewritten base means "true". Otherwise the job passes without booting a VM and
  says so in its summary. A new input of the checks outside those paths extends that list.
- Every test case is hermetic: no case reaches a real host, the tailnet, 1Password, Onidel,
  Cloudflare, the Pulumi state or the internet. The image and flake builds that run before the cases
  fetch only pinned inputs. `bun run drift` is a read-only check of a refactor, never part of a test.

## No test reaches a real host

This rule is stricter than the shared skill, because the tests here drive scripts that operate the
live host.

- Nothing in a test, a stand-in or a check runs `ssh`, `scp`, `sftp`, `rsync` or `tailscale`
  against a destination that is not loopback. OpenSSH reads the user's config from the passwd home,
  not `$HOME`, so a test-looking `ssh root@geoffcloud` reaches the real host.
- A shell suite whose script can call one of those tools writes a fail-closed stand-in for each of
  them in `$tree/bin`, and `setup_test` calls `require_remote_tool_stubs` before the act, so a
  missing stand-in fails the case instead of falling back to `/usr/bin`.
- A stand-in hands a call to the real tool only for a loopback destination: ssh for
  `ssh://<user>@127.0.0.1:<port>` with `-F /dev/null` and no option after the destination; docker
  for a `unix://` socket that normalises to a path inside the case tree. The real binary comes from
  a fixed system path, resolved when the stand-in is created.
- A failure that real state can produce comes from real state on loopback: a dead port
  (`127.0.0.1:1`), a missing socket, a directory without write permission.
- A DNS lookup (`getent hosts`) and a curl to a URL that is not loopback get stand-ins too. A real
  `getent` in a stand-in's own test reads the hosts file only (`-s files`).
- The real `gh` runs only with `GH_TELEMETRY=0 DO_NOT_TRACK=1 GH_NO_UPDATE_NOTIFIER=1`, in a case
  and in the fixture builds alike, because gh otherwise sends telemetry and checks for updates.
- A stand-in that speaks TLS hands its certificate to the client through the case's environment
  (`SSL_CERT_FILE`, with `SSL_CERT_DIR` set to an empty case directory), never through a trust
  store outside the case.

## infra (TypeScript)

`infra/` is in the pure regime: every unit under test is a builder or a validator that returns a
value. Resource-creating modules stay thin, and their logic lives in an exported `build*`,
`require*`, `find*` or `to*` function in its own file, which the test calls directly. The
health-check worker in `workers/` is HTTP-mocked.

- The `bunfig.toml` preload registers `@zgeoff/bun-test-extended`, runs
  `infra/test-utils/seed-faker.ts`, which seeds faker once per run, and runs
  `workers/mocks/register-mock-server.ts`, which starts the MSW server.
- Beside the preload, `infra/test-utils/` holds the shared test utils, each with its own test file:
  - `buildMock<Type>` factories fill every field: faker values for arbitrary fields, a fixed value
    for constrained ones. A test passes `undefined` for a field whose absence it tests, and passes
    as an override every field its assertions depend on.
  - `buildStubConfig` stands in for Pulumi's `Config`: `get` returns the raw string and `getObject`
    parses it, throwing the `RunError` the real `Config` throws for non-JSON. Modules take their
    stack config and `env` as arguments from `index.ts`, so a test never touches `process.env` or
    the Pulumi runtime.
  - `resolveOutput` reads an `Output`'s value. Assert secrecy with `isSecret`, separately from the
    value.
  - `buildStubR2Bucket` is an in-memory R2 bucket.
- The health-check worker's logic is tested through `makeScheduledHandler(destination)` in
  `workers/health-check/make-scheduled-handler.ts`: each test injects a recording destination and
  asserts every logged change of state through it, never by replacing the global console.
  `index.test.ts` checks the module Workers loads: its default export's `scheduled`, wired to
  `console`. `buildStubR2Bucket` implements `Pick<R2Bucket, 'get' | 'put'>` from
  `@cloudflare/workers-types` with R2's full object shapes, and rejects options and non-string
  values instead of modelling them. Its HTTP boundary is
  MSW handlers in `workers/mocks/` over two in-memory stores: the probe targets' statuses and the
  alerts sent. The server runs with `onUnhandledRequest: 'error'`, and the preload also fails the
  test on any `request:unhandled` event, because the worker turns a failed probe into a status
  instead of throwing. A dead target is a per-test `passthrough()` to `127.0.0.1:1`, so the
  connection really fails.
- Pass an `Output` input by reference (`output('…')`) and put the same object in the expected
  literal: `toStrictEqual` fails when a builder swaps or rebuilds it.
- A hand-written spec (alert rules, Helm values, a Deployment spec, the tailnet policy) is asserted
  whole with `toStrictEqual` against a literal, never an inline snapshot.
- `expect.stringMatching` returns `any`, which the lint rule `no-unsafe-assignment` refuses inside a
  literal. Use the typed `expect.toSatisfy((value: string) => /…/u.test(value))`.

## provider (Go)

Each shared rule takes its Go form:

| Shared rule                        | Go form                                                                                                                                         |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `test.each` for a closed table     | a `[]struct{…}` slice of plain data (never a map, never a `func` field) ranged with `t.Run("it …", …)`; every row fits the test function's name |
| `setupTest()` and its dispose      | `setupTest(t)` returning one struct held as `ctx`; `t.Cleanup` on the line after each acquisition; no `defer`, `TestMain` or `init`              |
| `onTestFinished` for process state | `t.Setenv`, `t.Chdir`, `t.Cleanup`                                                                                                              |
| `toStrictEqual`                    | `assert.Equal` against a complete struct, map or slice; `assert.ElementsMatch` where order is not the contract; `EqualValues` never appears      |
| Error strictness                   | `require.ErrorAs` plus a whole-value compare for a typed error, `require.ErrorIs` for a sentinel, `assert.EqualError` when the text is contract |
| Narrowing                          | `require.*` before an `assert.Empty`, `Nil`, `NotContains` or `Zero`, which pass on a missing value                                             |
| No sleeps; injected time           | `Client.Sleep` and `Client.VMWaitTimeout`, or `onidel.NewWithOptions(Options{Sleep})`; `testing/synctest` for the default sleep itself          |

- Tests are black-box (`package client_test`, `package onidel_test`) and sit in the file named for
  the source file they test. One approved exception: `client_internal_test.go` (`package client`)
  tests `sendRequest`'s body-encode failure, which no exported method can reach, with a real
  `json.Marshal` failure on a channel and no injected encoder.
- One `assert.Equal` holds one result. Never build a `[]any` or other composite on the actual side
  from several results; a projection of one result, such as a response's status and body, stays
  together.
- `internal/onideltest` holds the shared stand-ins, each with tests that pin it to the real thing:
  - `StartStubOnidelAPI` stands in for the Onidel API and is checked against
    `provider/spec/onidel.yaml`. It starts with no teams; a test states its team with `SetTeams`.
    It answers an unhandled route, an action it does not model, or a body that is not JSON with a
    recorded problem, and fails the test at cleanup when a problem was not drained.
  - `BuildStubSleep` records each duration and returns the context's error, and
    `BuildStubCancelingSleep` ends the caller's context. Their tests compare both with the real
    client `Sleep`.
  - `BuildStubTB` lets a test observe a helper failing a test, with `testing.T`'s cleanup order.
  - Shape the stub's state with its setters. A deviation is `RegisterResponse`; a handler that must
    change state mid-request, or a transport fault `RegisterResponse` cannot express (such as a
    body shorter than its `Content-Length`), is `RegisterHandler`. Assert the requests the code sent with
    `GetRequests()`, as a whole list.
- Run `bun run provider:check` (`gofmt`, `go vet`, then `go test -race ./...`), then
  `go test -race -shuffle=on -count=3 ./...`. A test that touches a context or time also passes
  `-count=200` before it lands.

## Shell suites

`scripts/test-<script>.sh` tests `scripts/<script>.sh`. A test of a deploy artifact sits beside it
(`deploy/atc-gateway/test-atc-gateway-image.sh`), and a journey sits in `e2e/`, one file per
journey. Each shared rule takes its shell form:

| Shared rule                  | Shell form                                                                                                                                                                                                         |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `test('it …')`               | a function `it_<words>`; its title is the name with spaces; `CASE='<part of a title>'` runs the matching cases                                                                                                     |
| `#<unit> <behaviour>`        | `it <unit> <behaviour>` in a file that tests several units, here and in the NixOS checks; the runners keep "it" as the first word, and Bun tests keep the shared `#<unit>` form                                       |
| The runner                   | `run_cases` from `scripts/test-lib/run-cases.sh`: each case in its own errexit subshell, `ok`/`FAIL` per case, exit 1 on any failure or when no case ran                                                            |
| `setupTest()`                | one `setup_test` per suite: a fresh `mktemp -d` tree and the stand-ins every case needs, with no scenario data; its config chooses which stand-ins to wire                                                          |
| Dispose and `onTestFinished` | one `trap '…' EXIT` per case, because bash keeps one EXIT trap: on the line after `mktemp -d`, before `setup_test` acquires containers or processes, with each step safe when its resource was never reached; in a trap with more than one step, every step ends `\|\| true`; a variable a step reads is global, since a `local` is gone when the trap runs |
| Every test stands alone      | the script under test runs under `env -i` with an explicit `PATH`, `HOME` and `TMPDIR` inside the case tree; git with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`; each suite starts with `umask 022` |
| `toStrictEqual`              | the whole stdout, stderr and stand-in call log compared with `diff` against a heredoc, or the `assert_*` helpers in `scripts/test-lib/`; mask only a temp path, a generated id, or a measurement that changes between runs (a wall-clock time, a duration, a size, a memory or CPU reading), never the value under test                                     |
| Exact errors                 | the exact exit code, never "non-zero", plus the exact stderr                                                                                                                                                       |
| Polling `waitFor`            | `wait_for <seconds> <what> <command…>` from `scripts/test-lib/wait-for.sh`                                                                                                                                         |
| Injected time                | `WAIT_FOR_CLOCK` and `WAIT_FOR_SLEEP`, stepped by `create_stub_clock`, so a timeout case counts pauses instead of waiting out seconds; the defaults are covered by a polled command that advances bash's `SECONDS` and by the clock's pause first on `PATH` as `sleep`; a script that embeds `date` output gets a `date` wrapper reading a fixed time |
| Reproducible data            | random values derive from `SEED`, which the run prints                                                                                                                                                             |

- A stand-in lives in `scripts/test-lib/` with its own `test-<file>.sh`, never inline in a suite:
  `create-stub-<thing>.sh` writes an executable to disk, and `start-stub-<thing>.sh` runs a process.
- A stand-in that replaces a tool logs its argv as one JSON line, matches the real tool's exit codes
  and messages, and ends with `*) echo "unexpected: $*" >&2; exit 97`. Where the real tool's output
  differs between the versions CI and a developer run, a comment names both versions and the test
  accepts each version's output only with its own exit code, through `assert_one_of_outputs`, which
  binds each version's stdout, stderr and exit status together. A process stand-in records an
  unexpected request and answers it with a failure.
- A stand-in that wraps the real tool, such as `create-stub-racing-git.sh`, or that supplies a value
  rather than a tool, such as `create-stub-clock.sh`, states in its header what it changes, and its
  test pins that change.
- A stand-in checked against documentation rather than the real tool, such as `create-stub-op.sh`,
  records the pages, the tool version and the check date in its header, and lists what the docs
  leave unsettled.
- An ssh stand-in that cannot run the remote command, because it needs root or a container,
  answers as the host would, and the case writes out the whole remote command as the expected argv.
  One that runs the command locally runs it under `env -i` from the case's host directory.
- A guard's tests pass it a search path the case owns, so its expected text never depends on the
  host.
- A producer whose output a case compares writes to a file under errexit first, so a failing
  producer fails the case instead of producing an empty match.
- Every other helper in `scripts/test-lib/` exports one public function, named for its file, and
  has its own `test-<helper>.sh` that `test:scripts` runs, or `test:atc-gateway-fixture` when it needs
  Docker.
- The Docker suites run under `scripts/test-lib/with-fixture-images.sh`, which builds the images
  once per run under tags that carry a random run id and removes them after. Every container and
  volume name carries that id, and each case's trap removes its containers before its volumes. The
  images run as production runs them: uid 65532, no capabilities, no privilege escalation.

## NixOS checks

The checks live in `nixos/checks/` and are wired into `checks.x86_64-linux`. `bun run test:nixos`
builds every check the flake declares, from the repo root as the flake source (`path:.?dir=nixos`),
because every check reads `scripts/test-lib/`. It builds in a `nixos/nix` container on the
`cloud-nixos-checks-store` volume, never the switch's `geoffcloud-nix-store`.

- A module check renders its cases through `nixos/checks/test-utils/render-cases.nix` into
  `run_cases` calls, each in its own fresh directory, with the `assert_*` helpers.
- Shared Nix helpers and stand-ins live in `nixos/checks/test-utils/`, one export per file, and the
  `test-utils` check tests each of them. Every check that uses them depends on that check. The impd
  stand-ins are compared with the real Elysia and Bun versions the pinned imp locks.
- A unit or config is asserted whole: `jq -S` of the evaluated `serviceConfig`, `environment`,
  `description`, `restartTriggers` or generated file against a literal, with store paths
  interpolated by Nix.
- A module assertion has a negative case that evaluates a bad config and compares the failing
  assertion messages exactly.
- The restore rehearsals (`impd-restore`, `impd-restore-seams`, `impd-restore-saved-failures`)
  share one VM definition and one reset, `setup_test()`. Each check boots its own VM, and each
  subtest supplies its own scenario data. `impd-restore-reset` checks the reset itself: each
  subtest leaves one kind of state behind, proves it is there, runs `setup_test()` and asserts the
  whole clean baseline. Cleanup that depends on what a subtest left lives in the reset, never in
  scenario flags. This is the language form of the shared skill's one `setupTest` per file.
- `setup_test()` returns the generated system paths as runtime handles, like a temporary
  directory. Each subtest names its restore generation and other scenario values in its own body.
- In a restore rehearsal, each `with subtest("it …")` starts
  from `setup_test()`, which resets every state a subtest can leave. It asserts
  `machine.execute`'s status and output exactly, masking only what the shell compares may mask,
  plus every side effect the script promises, including the saved original on each failure path.
  Waits use `wait_for_unit`, `wait_until_succeeds` or `wait_for`.
- An error the script declares is reached through real VM state where real state can produce it,
  and through the script's injectable commands (`SQLITE3`, `SYSTEMCTL`, `CMP`, the start loop's
  pause `IMPD_START_SLEEP`, and the health probe's `CURL`) only where it cannot. The start wait
  is counted through `build-stub-sleep` and the probe's timeout arguments are checked through
  `build-stub-curl`, never by waiting out a deadline. Two cases wait out a real 1 s curl timeout
  against the hung impd stand-in, with no elapsed-time assertion: the stand-in's own test in
  `test-utils`, which also checks `build-stub-curl` against that real curl, and one probe case
  in `impd-local-health`, the only real-transport proof that a hung impd reads as status 0.
- A rehearsal's first subtests assert that no unit failed at boot and that `systemd-detect-virt`
  prints `kvm`, so a run that fell back to emulation fails. `test-nixos.sh` needs a readable and
  writable KVM device for any `impd-restore*` check.
- nixpkgs passes a VM test script as one environment variable, capped at 131,072 bytes. A rehearsal
  that would pass the cap becomes a new `impd-restore-<area>` check, never a shorter rewrite of
  existing subtests.
