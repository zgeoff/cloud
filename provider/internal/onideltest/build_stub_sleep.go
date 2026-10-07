package onideltest

import (
	"context"
	"slices"
	"sync"
	"time"
)

// StubSleep stands in for the API client's Sleep (client.Client.Sleep and
// onidel.Options.Sleep): it returns at once and records each duration it was asked
// to wait. Like the real Sleep, it returns the context's error, so a call whose
// context has ended still stops. It is safe for concurrent use.
type StubSleep struct {
	mu        sync.Mutex
	durations []time.Duration
}

// BuildStubSleep returns a StubSleep that has recorded nothing.
func BuildStubSleep() *StubSleep {
	return &StubSleep{}
}

// Sleep records d and returns ctx's error at once.
func (s *StubSleep) Sleep(ctx context.Context, d time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.durations = append(s.durations, d)
	return ctx.Err()
}

// GetDurations returns the durations recorded so far, in order, or nil for none.
func (s *StubSleep) GetDurations() []time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.durations)
}
