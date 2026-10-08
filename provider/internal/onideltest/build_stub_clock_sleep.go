package onideltest

import (
	"context"
	"slices"
	"sync"
	"time"
)

// StubClockSleep stands in for the API client's Sleep (client.Client.Sleep) on a
// clock of its own: each sleep returns at once and moves the clock on by its
// duration. Like the real Sleep, it stops at the context's deadline: a sleep that
// would reach the deadline moves the clock to it and returns
// context.DeadlineExceeded, and a context that has already ended returns its error.
// The clock starts at the wall-clock time the stub was built, so a deadline set
// from the wall clock after that falls on the stub's clock where it would fall in
// real time. It is safe for concurrent use.
type StubClockSleep struct {
	mu        sync.Mutex
	now       time.Time
	durations []time.Duration
}

// BuildStubClockSleep returns a StubClockSleep whose clock reads the current time
// and which has recorded nothing.
func BuildStubClockSleep() *StubClockSleep {
	return &StubClockSleep{now: time.Now()}
}

// Sleep records d and moves the clock on by d, or to ctx's deadline when that
// comes first.
func (s *StubClockSleep) Sleep(ctx context.Context, d time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.durations = append(s.durations, d)
	if err := ctx.Err(); err != nil {
		return err
	}
	wake := s.now.Add(d)
	if deadline, ok := ctx.Deadline(); ok && !wake.Before(deadline) {
		s.now = deadline
		return context.DeadlineExceeded
	}
	s.now = wake
	return nil
}

// GetNow returns the time on the stub's clock.
func (s *StubClockSleep) GetNow() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.now
}

// GetDurations returns the durations recorded so far, in order, or nil for none.
func (s *StubClockSleep) GetDurations() []time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.durations)
}
