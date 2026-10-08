package onideltest_test

import (
	"context"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestBuildStubClockSleepRecordsNothingAtFirst(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		start := time.Now()

		sleep := onideltest.BuildStubClockSleep()

		assert.Equal(t, []time.Duration(nil), sleep.GetDurations())
		assert.Equal(t, start, sleep.GetNow())
	})
}

func TestBuildStubClockSleepMovesItsClockOnByEachDuration(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		start := time.Now()
		sleep := onideltest.BuildStubClockSleep()

		first, second := sleep.Sleep(t.Context(), time.Second), sleep.Sleep(t.Context(), time.Hour)

		require.NoError(t, first)
		require.NoError(t, second)
		assert.Equal(t, []time.Duration{time.Second, time.Hour}, sleep.GetDurations())
		assert.Equal(t, start.Add(time.Hour+time.Second), sleep.GetNow())
	})
}

func TestBuildStubClockSleepEndsAtTheContextsDeadlineAsTheClientsSleepDoes(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		start := time.Now()
		ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
		t.Cleanup(cancel)
		plain := client.New("", "key")
		stub := onideltest.BuildStubClockSleep()
		stubbed := client.New("", "key")
		stubbed.Sleep = stub.Sleep

		// The stub runs first, while ctx is still live; the real Sleep then waits out
		// the deadline on the bubble's clock.
		got, want := stubbed.Sleep(ctx, time.Minute), plain.Sleep(ctx, time.Minute)

		assert.Equal(t, context.DeadlineExceeded, got)
		assert.Equal(t, context.DeadlineExceeded, want)
		assert.Equal(t, start.Add(30*time.Second), stub.GetNow())
		assert.Equal(t, 30*time.Second, time.Since(start))
	})
}

func TestBuildStubClockSleepSleepsInFullBeforeTheDeadlineAsTheClientsSleepDoes(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		start := time.Now()
		ctx, cancel := context.WithTimeout(t.Context(), time.Hour)
		t.Cleanup(cancel)
		plain := client.New("", "key")
		stub := onideltest.BuildStubClockSleep()
		stubbed := client.New("", "key")
		stubbed.Sleep = stub.Sleep

		got, want := stubbed.Sleep(ctx, time.Minute), plain.Sleep(ctx, time.Minute)

		require.NoError(t, got)
		require.NoError(t, want)
		assert.Equal(t, start.Add(time.Minute), stub.GetNow())
		assert.Equal(t, time.Minute, time.Since(start))
	})
}

func TestBuildStubClockSleepReturnsTheClientsSleepErrorForACanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	plain := client.New("", "key")
	stubbed := client.New("", "key")
	stubbed.Sleep = onideltest.BuildStubClockSleep().Sleep

	want, got := plain.Sleep(ctx, time.Hour), stubbed.Sleep(ctx, time.Hour)

	assert.Equal(t, context.Canceled, want)
	assert.Equal(t, context.Canceled, got)
}
