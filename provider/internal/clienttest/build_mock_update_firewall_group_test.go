package clienttest_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/clienttest"
	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

func TestBuildMockUpdateFirewallGroupBuildsADefaultUpdateFirewallGroup(t *testing.T) {
	assert.Equal(t, onidelapi.UpdateFirewallGroup{TeamID: "team-a", Description: "edge"}, clienttest.BuildMockUpdateFirewallGroup())
}

func TestBuildMockUpdateFirewallGroupAppliesOverridesOnTopOfTheDefaults(t *testing.T) {
	assert.Equal(t, onidelapi.UpdateFirewallGroup{Description: "edge 2"}, clienttest.BuildMockUpdateFirewallGroup(func(in *onidelapi.UpdateFirewallGroup) { in.TeamID, in.Description = "", "edge 2" }))
}
