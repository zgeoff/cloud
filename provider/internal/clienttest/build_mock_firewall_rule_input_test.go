package clienttest_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/clienttest"
)

func TestBuildMockFirewallRuleInputBuildsADefaultFirewallRuleInput(t *testing.T) {
	assert.Equal(t, client.FirewallRuleInput{TeamID: "team-a", Protocol: "tcp", Port: "443", Subnet: "203.0.113.0", SubnetSize: 24, Description: "web"}, clienttest.BuildMockFirewallRuleInput())
}

func TestBuildMockFirewallRuleInputAppliesOverridesOnTopOfTheDefaults(t *testing.T) {
	assert.Equal(t, client.FirewallRuleInput{TeamID: "team-a", Protocol: "icmp", Subnet: "203.0.113.0", Description: "web"}, clienttest.BuildMockFirewallRuleInput(func(in *client.FirewallRuleInput) { in.Protocol, in.Port, in.SubnetSize = "icmp", "", 0 }))
}
