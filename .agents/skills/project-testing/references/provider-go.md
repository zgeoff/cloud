# provider (Go)

Write the Go tests in `provider/` with testify, as the Departures of
[project-testing](../SKILL.md#departures) say. These rules give each rule of
[Go testing](../../testing/references/go.md) its testify form, and name the provider's stand-ins.

- [Shape](#shape)
- [Assertions](#assertions)
- [The stub Onidel API](#the-stub-onidel-api)
- [Time](#time)
- [Running the tests](#running-the-tests)

## Shape

- Write black-box tests: a test of `internal/client/firewalls.go` goes in `firewalls_test.go` as
  `package client_test`.
- Write a table of fixed cases as a `[]struct{…}` slice of plain data, and range it with
  `t.Run("it …", …)`. Never use a map, whose order is random, or a `func` field, which hides the
  case's logic.
- Build each test's state in one `setupTest(t)`, which returns a struct. Register its cleanup with
  `t.Cleanup` inside it. Never set up or clean up with `defer`, `TestMain` or `init`.
- Test `cmd/onidel` through the binary that `main_test.go` builds with `go build`, run against the
  stub API.

## Assertions

- Compare a whole struct, map or slice with `assert.Equal`. Use `assert.ElementsMatch` when the order
  isn't part of the contract. Never use `assert.EqualValues`, which converts types before it
  compares.
- Hold one result in each `assert.Equal`. Never build a `[]any` of several results to compare at
  once.
- Check a typed error with `require.ErrorAs`, then compare the whole value. Check a sentinel with
  `require.ErrorIs`. Use `assert.EqualError` only when the text is the contract.
- Before `assert.Empty`, `assert.Nil`, `assert.NotContains` or `assert.Zero`, check that the value
  exists with a `require` call, such as `require.Len`. Those four pass on a missing value.
- Build each request the client sends with a `BuildMock<Type>` from
  [`internal/clienttest`](../../../../provider/internal/clienttest/). Its defaults are fixed values,
  because the tests compare request bodies exactly. Set every field the test asserts, even when it
  matches the default. Add a `BuildMock<Type>` there, with its test, for a new request type.

## The stub Onidel API

Run the client against
[`StartStubOnidelAPI`](../../../../provider/internal/onideltest/start_stub_onidel_api.go), in
[`internal/onideltest`](../../../../provider/internal/onideltest/). It checks each request against
[`onidel.yaml`](../../../../provider/spec/onidel.yaml) and
[`onidel.overlay.yaml`](../../../../provider/spec/onidel.overlay.yaml), and records each request it
can't answer as a problem.

- Call `DrainProblems` in each test that expects a problem, and compare its result. At cleanup, the
  stub fails the test on any problem left.
- Set the starting state with the stub's `Set*` methods. It starts with no teams, so call `SetTeams`
  in each test that reaches a team.
- Use `RegisterResponse` for a canned answer that differs from the stub's model. Use
  `RegisterHandler` only for a state change during a request, or for a transport fault, such as a
  body shorter than its `Content-Length`.
- Compare the whole `GetRequests()` list in each test that asserts what the client sent.
- Observe a helper that fails a test through
  [`BuildStubTB`](../../../../provider/internal/onideltest/build_stub_tb.go).

## Time

Pass a stub sleep through `Client.Sleep` in
[`client.go`](../../../../provider/internal/client/client.go) in a client test, or
`Options{Sleep}` in [`provider.go`](../../../../provider/internal/onidel/provider.go) in a provider
test:

- [`BuildStubSleep`](../../../../provider/internal/onideltest/build_stub_sleep.go) records each wait.
- [`BuildStubCancelingSleep`](../../../../provider/internal/onideltest/build_stub_canceling_sleep.go)
  cancels the caller's context.
- [`BuildStubClockSleep`](../../../../provider/internal/onideltest/build_stub_clock_sleep.go) moves
  its own clock and returns `context.DeadlineExceeded` at the deadline. Use it with a short
  `Client.VMWaitTimeout` to test a timeout.

## Running the tests

From the repo root, run `bun run provider:check`. Then, from `provider/`, run
`go test -race -shuffle=on -count=3 ./...`. Before you push a test that touches a context or time,
run it alone with `-race -count=200`.
