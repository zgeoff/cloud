package onideltest_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestBuildStubTBRecordsAFailureWithoutFailingTheWrappedTest(t *testing.T) {
	stub := onideltest.BuildStubTB(t)

	stub.Errorf("saw %d problems", 2)
	stub.Error("saw", "one more")

	assert.True(t, stub.Failed())
	assert.Equal(t, []string{"saw 2 problems", "saw one more\n"}, stub.GetErrors())
}

func TestBuildStubTBReportsNoFailureAtFirst(t *testing.T) {
	stub := onideltest.BuildStubTB(t)

	assert.False(t, stub.Failed())
	assert.Equal(t, []string(nil), stub.GetErrors())
}

func TestBuildStubTBHoldsCleanupsUntilRunCleanupsRunsThemOnceLastFirst(t *testing.T) {
	stub := onideltest.BuildStubTB(t)
	var ran []string
	stub.Cleanup(func() { ran = append(ran, "first") })
	stub.Cleanup(func() { ran = append(ran, "second") })
	held := len(ran)

	stub.RunCleanups()
	stub.RunCleanups()

	assert.Equal(t, 0, held)
	assert.Equal(t, []string{"second", "first"}, ran)
}

func TestBuildStubTBRunsHeldCleanupsWhenTheWrappedTestEnds(t *testing.T) {
	var ran []string

	t.Run("it holds a cleanup", func(t *testing.T) {
		stub := onideltest.BuildStubTB(t)
		stub.Cleanup(func() { ran = append(ran, "cleanup") })
	})

	assert.Equal(t, []string{"cleanup"}, ran)
}

func TestBuildStubTBEndsOnlyTheRunFunctionOnARequireFailure(t *testing.T) {
	stub := onideltest.BuildStubTB(t)
	reached := false

	stub.Run(func() {
		require.Equal(stub, "want", "got")
		reached = true
	})

	assert.False(t, reached)
	assert.True(t, stub.Failed())
	assert.Len(t, stub.GetErrors(), 1)
}

func TestBuildStubTBEndsTheRunFunctionOnFatalf(t *testing.T) {
	stub := onideltest.BuildStubTB(t)
	reached := false

	stub.Run(func() {
		stub.Fatalf("stop at %s", "here")
		reached = true
	})

	assert.False(t, reached)
	assert.Equal(t, []string{"stop at here"}, stub.GetErrors())
}

func TestBuildStubTBEndsTheRunFunctionOnFatal(t *testing.T) {
	stub := onideltest.BuildStubTB(t)
	reached := false

	stub.Run(func() {
		stub.Fatal("stop")
		reached = true
	})

	assert.False(t, reached)
	assert.Equal(t, []string{"stop\n"}, stub.GetErrors())
}

func TestBuildStubTBRunsACleanupRegisteredByACleanupInTheSamePass(t *testing.T) {
	stub := onideltest.BuildStubTB(t)
	var ran []string
	stub.Cleanup(func() {
		ran = append(ran, "outer")
		stub.Cleanup(func() { ran = append(ran, "nested") })
	})

	stub.RunCleanups()

	assert.Equal(t, []string{"outer", "nested"}, ran)
}

func TestBuildStubTBRunsTheOtherCleanupsAfterOneCallsFatalf(t *testing.T) {
	stub := onideltest.BuildStubTB(t)
	var ran []string
	stub.Cleanup(func() { ran = append(ran, "first") })
	stub.Cleanup(func() {
		stub.Fatalf("stop")
		ran = append(ran, "unreached")
	})

	stub.RunCleanups()

	assert.Equal(t, []string{"first"}, ran)
	assert.Equal(t, []string{"stop"}, stub.GetErrors())
}

// The wrapped test is itself a StubTB here, so ending it (its RunCleanups) shows what
// the inner stub reports to it without failing this test.
func TestBuildStubTBFailsTheWrappedTestOnAFailureItsEndOfTestCleanupsRecord(t *testing.T) {
	wrapped := onideltest.BuildStubTB(t)
	stub := onideltest.BuildStubTB(wrapped)
	stub.Cleanup(func() { stub.Errorf("left %d problems", 1) })

	wrapped.RunCleanups()

	assert.Equal(t, []string{"left 1 problems"}, wrapped.GetErrors())
}

func TestBuildStubTBKeepsAFailureRecordedBeforeTheWrappedTestEnds(t *testing.T) {
	wrapped := onideltest.BuildStubTB(t)
	stub := onideltest.BuildStubTB(wrapped)
	stub.Errorf("asserted by the test")

	wrapped.RunCleanups()

	assert.Equal(t, []string(nil), wrapped.GetErrors())
	assert.Equal(t, []string{"asserted by the test"}, stub.GetErrors())
}
