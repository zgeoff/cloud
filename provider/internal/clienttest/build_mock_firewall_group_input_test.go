package clienttest_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/clienttest"
)

func TestBuildMockFirewallGroupInputBuildsADefaultFirewallGroupInput(t *testing.T) {
	assert.Equal(t, client.FirewallGroupInput{TeamID: "team-a", Description: "edge"}, clienttest.BuildMockFirewallGroupInput())
}

func TestBuildMockFirewallGroupInputAppliesOverridesOnTopOfTheDefaults(t *testing.T) {
	assert.Equal(t, client.FirewallGroupInput{Description: "edge 2"}, clienttest.BuildMockFirewallGroupInput(func(in *client.FirewallGroupInput) { in.TeamID, in.Description = "", "edge 2" }))
}
