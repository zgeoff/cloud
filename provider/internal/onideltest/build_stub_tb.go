package onideltest

import (
	"fmt"
	"runtime"
	"slices"
	"sync"
	"testing"
)

// StubTB stands in for a testing.TB whose failure a test must observe: it records
// each failure reported to it instead of failing the wrapped test, and holds each
// cleanup until RunCleanups, or until the wrapped test ends. Every other method
// passes through to the wrapped TB, so Context and TempDir still work.
type StubTB struct {
	testing.TB

	mu       sync.Mutex
	failed   bool
	errors   []string
	cleanups []func()
}

// BuildStubTB wraps t. Cleanups still held when t ends run then.
func BuildStubTB(t testing.TB) *StubTB {
	s := &StubTB{TB: t}
	t.Cleanup(s.RunCleanups)
	return s
}

// Run calls fn on its own goroutine and waits for it, so a FailNow inside fn (such as
// a failed require assertion) ends fn without ending the calling test.
func (s *StubTB) Run(fn func()) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		fn()
	}()
	<-done
}

// RunCleanups runs the cleanups held so far, last registered first, and forgets them.
func (s *StubTB) RunCleanups() {
	s.mu.Lock()
	cleanups := s.cleanups
	s.cleanups = nil
	s.mu.Unlock()
	for _, cleanup := range slices.Backward(cleanups) {
		cleanup()
	}
}

// GetErrors returns the failure messages reported so far, in order.
func (s *StubTB) GetErrors() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.errors)
}

// Cleanup holds f until RunCleanups.
func (s *StubTB) Cleanup(f func()) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cleanups = append(s.cleanups, f)
}

// Helper does nothing: the stub reports no file and line.
func (s *StubTB) Helper() {}

// Error records a failure message built as fmt.Sprintln builds one.
func (s *StubTB) Error(args ...any) {
	s.Errorf("%s", fmt.Sprintln(args...))
}

// Errorf records a failure message built as fmt.Sprintf builds one.
func (s *StubTB) Errorf(format string, args ...any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failed = true
	s.errors = append(s.errors, fmt.Sprintf(format, args...))
}

// Fail marks the stub as failed.
func (s *StubTB) Fail() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failed = true
}

// Failed reports whether a failure was reported.
func (s *StubTB) Failed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.failed
}

// FailNow marks the stub as failed and ends the calling goroutine, as testing.T's
// does. Call it only inside Run.
func (s *StubTB) FailNow() {
	s.Fail()
	runtime.Goexit()
}

// Fatal records a failure message, then ends the calling goroutine.
func (s *StubTB) Fatal(args ...any) {
	s.Error(args...)
	s.FailNow()
}

// Fatalf records a failure message, then ends the calling goroutine.
func (s *StubTB) Fatalf(format string, args ...any) {
	s.Errorf(format, args...)
	s.FailNow()
}
