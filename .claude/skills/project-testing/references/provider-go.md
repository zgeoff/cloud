# provider (Go)

The Go provider's tests take each shared rule in its Go form, and share the stand-ins in
[`internal/onideltest`](../../../../provider/internal/onideltest/).

| Shared rule                        | Go form                                                                                                                                                                                                                                                                                  |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test.each` for a closed table     | a `[]struct{…}` slice of plain data (never a map, never a `func` field) ranged with `t.Run("it …", …)`; every row fits the test function's name                                                                                                                                          |
| `setupTest()` and its dispose      | `setupTest(t)` returning one struct held as `ctx`; `t.Cleanup` on the line after each acquisition; no `defer`, `TestMain` or `init`                                                                                                                                                      |
| `onTestFinished` for process state | `t.Setenv`, `t.Chdir`, `t.Cleanup`                                                                                                                                                                                                                                                       |
| `toStrictEqual`                    | `assert.Equal` against a complete struct, map or slice; `assert.ElementsMatch` where order is not the contract; `EqualValues` never appears                                                                                                                                              |
| Error strictness                   | `require.ErrorAs` plus a whole-value compare for a typed error, `require.ErrorIs` for a sentinel, `assert.EqualError` when the text is contract                                                                                                                                          |
| Narrowing                          | `require.*` before an `assert.Empty`, `Nil`, `NotContains` or `Zero`, which pass on a missing value                                                                                                                                                                                      |
| No sleeps; injected time           | `Client.Sleep` and `Client.VMWaitTimeout` in [`client.go`](../../../../provider/internal/client/client.go), or `onidel.NewWithOptions(Options{Sleep})` in [`provider.go`](../../../../provider/internal/onidel/provider.go); `testing/synctest` for the default sleep itself             |
| Factories (`buildMock<Type>`)      | `BuildMock<Type>(overrides ...func(*T)) T` in [`internal/clienttest`](../../../../provider/internal/clienttest/) for the generated request types the client sends, with fixed defaults, since the tests pin the request body as exact values; a test sets each field its assertion names |

- Tests are black-box (`package client_test`, `package onidel_test`) and sit in the file named for
  the source file they test. `cmd/onidel`'s tests build the real binary and run it against the stub
  API.
- One `assert.Equal` holds one result. Never build a `[]any` or other composite on the actual side
  from several results; a projection of one result, such as a response's status and body, stays
  together.
- [`internal/onideltest`](../../../../provider/internal/onideltest/) holds the shared stand-ins,
  each with tests that pin it to the real thing:
  - [`StartStubOnidelAPI`](../../../../provider/internal/onideltest/start_stub_onidel_api.go) stands
    in for the Onidel API. kin-openapi validates every request against the spec the client is
    generated from, [`onidel.yaml`](../../../../provider/spec/onidel.yaml) with its overlay, for the
    operations in use. It starts with no teams; a test states its team with `SetTeams`. It answers a
    request that does not match the spec, an unhandled route, an action it does not model, or a body
    that is not JSON with a recorded problem, and fails the test at cleanup when a problem was not
    drained.
  - [`BuildStubSleep`](../../../../provider/internal/onideltest/build_stub_sleep.go) records each
    duration and returns the context's error, and
    [`BuildStubCancelingSleep`](../../../../provider/internal/onideltest/build_stub_canceling_sleep.go)
    ends the caller's context.
    [`BuildStubClockSleep`](../../../../provider/internal/onideltest/build_stub_clock_sleep.go) runs
    its own clock: each sleep returns at once and moves the clock on, stopping at the context's
    deadline with `context.DeadlineExceeded`. Their tests compare each with the real client `Sleep`.
  - [`BuildStubTB`](../../../../provider/internal/onideltest/build_stub_tb.go) lets a test observe a
    helper failing a test, with `testing.T`'s cleanup order.
  - Shape the stub's state with its setters. A deviation is `RegisterResponse`; a handler that must
    change state mid-request, or a transport fault `RegisterResponse` cannot express (such as a body
    shorter than its `Content-Length`), is `RegisterHandler`. Assert the requests the code sent with
    `GetRequests()`, as a whole list.
- Run `bun run provider:check` ([`check.sh`](../../../../provider/check.sh): `gofmt`, `go vet`,
  golangci-lint, `deadcode -test`, then `go test -race ./...`), then
  `go test -race -shuffle=on -count=3 ./...`. A test that touches a context or time also passes
  `-count=200` before it lands.
