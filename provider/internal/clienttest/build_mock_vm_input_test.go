package clienttest_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/clienttest"
)

func TestBuildMockVMInputBuildsADefaultVMInput(t *testing.T) {
	assert.Equal(t, client.VMInput{Name: "web", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20, OS: new(24)}, clienttest.BuildMockVMInput())
}

func TestBuildMockVMInputAppliesOverridesOnTopOfTheDefaults(t *testing.T) {
	assert.Equal(t, client.VMInput{Name: "db", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20}, clienttest.BuildMockVMInput(func(in *client.VMInput) { in.Name, in.OS = "db", nil }))
}
