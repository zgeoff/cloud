package onideltest_test

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestBuildStubSleepRecordsNothingAtFirst(t *testing.T) {
	sleep := onideltest.BuildStubSleep()

	assert.Equal(t, []time.Duration(nil), sleep.GetDurations())
}

func TestBuildStubSleepRecordsEachDurationInOrder(t *testing.T) {
	sleep := onideltest.BuildStubSleep()

	first, second := sleep.Sleep(t.Context(), time.Second), sleep.Sleep(t.Context(), time.Hour)

	require.NoError(t, first)
	require.NoError(t, second)
	assert.Equal(t, []time.Duration{time.Second, time.Hour}, sleep.GetDurations())
}

func TestBuildStubSleepReturnsTheClientsSleepErrorForACanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	plain := client.New("", "key")
	stubbed := client.New("", "key")
	stubbed.Sleep = onideltest.BuildStubSleep().Sleep

	want, got := plain.Sleep(ctx, time.Hour), stubbed.Sleep(ctx, time.Hour)

	assert.Equal(t, context.Canceled, want)
	assert.Equal(t, context.Canceled, got)
}

func TestBuildStubSleepReturnsTheClientsSleepErrorForAnExpiredContext(t *testing.T) {
	ctx, cancel := context.WithDeadline(t.Context(), time.Unix(0, 0))
	t.Cleanup(cancel)
	plain := client.New("", "key")
	stubbed := client.New("", "key")
	stubbed.Sleep = onideltest.BuildStubSleep().Sleep

	want, got := plain.Sleep(ctx, time.Hour), stubbed.Sleep(ctx, time.Hour)

	assert.Equal(t, context.DeadlineExceeded, want)
	assert.Equal(t, context.DeadlineExceeded, got)
}
