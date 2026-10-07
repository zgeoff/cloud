package onideltest_test

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestBuildStubCancelingSleepEndsTheCallersContextAndReturnsItsError(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	t.Cleanup(cancel)
	c := client.New("", "key")
	c.Sleep = onideltest.BuildStubCancelingSleep(cancel).Sleep

	err := c.Sleep(ctx, time.Hour)

	assert.Equal(t, []error{context.Canceled, context.Canceled}, []error{err, ctx.Err()})
}
