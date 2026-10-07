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
	plain := client.New("", "key")
	stubbed := client.New("", "key")
	stubbed.Sleep = onideltest.BuildStubSleep().Sleep

	want, got := plain.Sleep(ctx, time.Hour), stubbed.Sleep(ctx, time.Hour)

	assert.Equal(t, []error{context.Canceled, context.Canceled}, []error{want, got})
}

func TestBuildStubSleepReturnsTheClientsSleepErrorForAnExpiredContext(t *testing.T) {
	ctx, cancel := context.WithDeadline(t.Context(), time.Unix(0, 0))
	t.Cleanup(cancel)
	plain := client.New("", "key")
	stubbed := client.New("", "key")
	stubbed.Sleep = onideltest.BuildStubSleep().Sleep

	want, got := plain.Sleep(ctx, time.Hour), stubbed.Sleep(ctx, time.Hour)

	assert.Equal(t, []error{context.DeadlineExceeded, context.DeadlineExceeded}, []error{want, got})
}
