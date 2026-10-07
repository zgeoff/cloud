package onideltest

import (
	"context"
	"time"
)

// StubCancelingSleep stands in for the API client's Sleep (client.Client.Sleep) at
// the moment the caller's context ends: its Sleep cancels that context, then returns
// the context's error, as the real Sleep does for an ended context.
type StubCancelingSleep struct {
	cancel context.CancelFunc
}

// BuildStubCancelingSleep returns a StubCancelingSleep that calls cancel on every
// sleep; the first call ends the context, and later calls change nothing. cancel must
// end the context the caller passes to the client.
func BuildStubCancelingSleep(cancel context.CancelFunc) *StubCancelingSleep {
	return &StubCancelingSleep{cancel: cancel}
}

// Sleep cancels the caller's context and returns ctx's error.
func (s *StubCancelingSleep) Sleep(ctx context.Context, _ time.Duration) error {
	s.cancel()
	return ctx.Err()
}
