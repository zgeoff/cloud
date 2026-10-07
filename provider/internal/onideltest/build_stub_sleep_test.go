package onideltest_test

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestBuildStubSleepRecordsNothingAtFirst(t *testing.T) {
	sleep := onideltest.BuildStubSleep()

	assert.Equal(t, []time.Duration(nil), sleep.GetDurations())
}

func TestBuildStubSleepRecordsEachDurationInOrder(t *testing.T) {
	sleep := onideltest.BuildStubSleep()

	errs := []error{sleep.Sleep(t.Context(), time.Second), sleep.Sleep(t.Context(), time.Hour)}

	assert.Equal(t, []any{[]error{nil, nil}, []time.Duration{time.Second, time.Hour}}, []any{errs, sleep.GetDurations()})
}

func TestBuildStubSleepReturnsTheClientsSleepErrorForACanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	c := client.New("", "key")
	want := c.Sleep(ctx, time.Hour)
	c.Sleep = onideltest.BuildStubSleep().Sleep

	got := c.Sleep(ctx, time.Hour)

	assert.Equal(t, []error{context.Canceled, context.Canceled}, []error{want, got})
}

func TestBuildStubSleepReturnsTheClientsSleepErrorForAnExpiredContext(t *testing.T) {
	ctx, cancel := context.WithDeadline(t.Context(), time.Unix(0, 0))
	t.Cleanup(cancel)
	c := client.New("", "key")
	want := c.Sleep(ctx, time.Hour)
	c.Sleep = onideltest.BuildStubSleep().Sleep

	got := c.Sleep(ctx, time.Hour)

	assert.Equal(t, []error{context.DeadlineExceeded, context.DeadlineExceeded}, []error{want, got})
}
