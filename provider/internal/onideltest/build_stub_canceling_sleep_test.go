package onideltest_test

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestBuildStubCancelingSleepEndsTheCallersContextAndReturnsTheClientsSleepError(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	t.Cleanup(cancel)
	plain := client.New("", "key")
	stubbed := client.New("", "key")
	stubbed.Sleep = onideltest.BuildStubCancelingSleep(cancel).Sleep

	// The stub's sleep runs first and ends ctx; the real Sleep then sees an ended context.
	got, want := stubbed.Sleep(ctx, time.Millisecond), plain.Sleep(ctx, time.Millisecond)

	assert.Equal(t, context.Canceled, got)
	assert.Equal(t, context.Canceled, want)
	assert.Equal(t, context.Canceled, ctx.Err())
}
