# provider (Go)

These rules add to [Go testing](../../testing/references/go.md) for the tests in `provider/`.

- [Shape and assertions](#shape-and-assertions)
- [Stand-ins](#stand-ins)
- [Running the tests](#running-the-tests)

## Shape and assertions

- Write black-box tests (`package client_test`, `package onidel_test`) in the file named for the
  source file they test. Test `cmd/onidel` by building the real binary and running it against the
  stub API.
- Write a closed table as a `[]struct{…}` slice of plain data, never a map or a `func` field, and
  range it with `t.Run("it …", …)`.
- Build each test's state in one `setupTest(t)` that returns a struct held as `ctx`. Never use
  `defer`, `TestMain` or `init` for setup or cleanup.
- Compare a whole struct, map or slice with `assert.Equal`, or with `assert.ElementsMatch` when order
  isn't the contract. Never use `EqualValues`.
- Check a typed error with `require.ErrorAs` and a compare of the whole value, a sentinel with
  `require.ErrorIs`, and the text with `assert.EqualError` only when the text is the contract.
- Narrow with `require.*` before `assert.Empty`, `Nil`, `NotContains` or `Zero`, which pass on a
  missing value.
- Hold one result in one `assert.Equal`. Never build a `[]any` from several results on the actual
  side.
- Build a request type the client sends with `BuildMock<Type>(overrides ...func(*T)) T` from
  [`internal/clienttest`](../../../../provider/internal/clienttest/). Its defaults are fixed values,
  because the tests pin the request body exactly. Set each field the assertion checks.

## Stand-ins

[`internal/onideltest`](../../../../provider/internal/onideltest/) holds the shared stand-ins, each
with tests that pin it to the real thing.

- Use [`StartStubOnidelAPI`](../../../../provider/internal/onideltest/start_stub_onidel_api.go) for
  the Onidel API. It validates each request against
  [`onidel.yaml`](../../../../provider/spec/onidel.yaml) and its overlay, starts with no teams, and
  fails the test at cleanup on any problem the test didn't drain. Set the team with `SetTeams`.
- Shape the stub's state with its setters. Use `RegisterResponse` for a deviation, and
  `RegisterHandler` only for a change mid-request or a transport fault, such as a body shorter than
  its `Content-Length`. Assert the whole `GetRequests()` list.
- Inject time through `Client.Sleep` and `Client.VMWaitTimeout` in
  [`client.go`](../../../../provider/internal/client/client.go), or `Options{Sleep}` in
  [`provider.go`](../../../../provider/internal/onidel/provider.go). Pass
  [`BuildStubSleep`](../../../../provider/internal/onideltest/build_stub_sleep.go),
  [`BuildStubCancelingSleep`](../../../../provider/internal/onideltest/build_stub_canceling_sleep.go)
  or [`BuildStubClockSleep`](../../../../provider/internal/onideltest/build_stub_clock_sleep.go).
- Use [`BuildStubTB`](../../../../provider/internal/onideltest/build_stub_tb.go) to observe a helper
  that fails a test.

## Running the tests

Run `bun run provider:check`, then `go test -race -shuffle=on -count=3 ./...` from `provider/`.
Before a test that touches a context or time lands, run it with `-count=200` too.
