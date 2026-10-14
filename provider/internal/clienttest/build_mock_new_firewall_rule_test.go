package clienttest_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/clienttest"
	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

func TestBuildMockNewFirewallRuleBuildsADefaultNewFirewallRule(t *testing.T) {
	assert.Equal(t, onidelapi.NewFirewallRule{TeamID: "team-a", Protocol: "tcp", Port: "443", Subnet: "203.0.113.0", SubnetSize: 24, Desc: "web"}, clienttest.BuildMockNewFirewallRule())
}

func TestBuildMockNewFirewallRuleAppliesOverridesOnTopOfTheDefaults(t *testing.T) {
	assert.Equal(t, onidelapi.NewFirewallRule{TeamID: "team-a", Protocol: "icmp", Subnet: "203.0.113.0", Desc: "web"}, clienttest.BuildMockNewFirewallRule(func(in *onidelapi.NewFirewallRule) { in.Protocol, in.Port, in.SubnetSize = "icmp", "", 0 }))
}
