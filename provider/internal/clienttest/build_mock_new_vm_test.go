package clienttest_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/clienttest"
	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

func TestBuildMockNewVMBuildsADefaultNewVM(t *testing.T) {
	assert.Equal(t, onidelapi.NewVM{Name: "web", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20, Os: new(int64(24))}, clienttest.BuildMockNewVM())
}

func TestBuildMockNewVMAppliesOverridesOnTopOfTheDefaults(t *testing.T) {
	assert.Equal(t, onidelapi.NewVM{Name: "db", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20}, clienttest.BuildMockNewVM(func(in *onidelapi.NewVM) { in.Name, in.Os = "db", nil }))
}
