package clienttest_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/clienttest"
	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

func TestBuildMockNewFirewallGroupBuildsADefaultNewFirewallGroup(t *testing.T) {
	assert.Equal(t, onidelapi.NewFirewallGroup{TeamID: "team-a", Description: "edge"}, clienttest.BuildMockNewFirewallGroup())
}

func TestBuildMockNewFirewallGroupAppliesOverridesOnTopOfTheDefaults(t *testing.T) {
	assert.Equal(t, onidelapi.NewFirewallGroup{Description: "edge 2"}, clienttest.BuildMockNewFirewallGroup(func(in *onidelapi.NewFirewallGroup) { in.TeamID, in.Description = "", "edge 2" }))
}
