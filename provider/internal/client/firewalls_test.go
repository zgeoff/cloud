package client_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestCreateFirewallGroupReturnsTheStoredGroup(t *testing.T) {
	ctx := setupTest(t)

	group, err := ctx.client.CreateFirewallGroup(t.Context(), client.FirewallGroupInput{TeamID: "team-a", Description: "edge"})

	require.NoError(t, err)
	assert.Equal(t, client.FirewallGroup{
		ID: "00000000-0000-4000-8000-000000000001", Description: "edge",
		Created: "2026-10-02T00:00:00Z", Updated: "2026-10-02T00:00:00Z",
	}, group)
}

func TestCreateFirewallGroupFailsWithoutATeam(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.client.CreateFirewallGroup(t.Context(), client.FirewallGroupInput{Description: "edge"})

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "POST", Path: "/network/firewalls", Status: 401, Code: "UNAUTHORIZED"}, apiErr)
}

func TestReadFirewallGroupReadsOneGroup(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{
		"id": "g1", "description": "edge", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-03T00:00:00Z",
		"instance_count": 1, "rule_count": 4,
	})

	group, err := ctx.client.ReadFirewallGroup(t.Context(), "g1")

	require.NoError(t, err)
	assert.Equal(t, client.FirewallGroup{
		ID: "g1", Description: "edge", Created: "2026-10-02T00:00:00Z", Updated: "2026-10-03T00:00:00Z", InstanceCount: 1, RuleCount: 4,
	}, group)
}

func TestUpdateFirewallGroupChangesTheDescription(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "description": "edge"})

	err := ctx.client.UpdateFirewallGroup(t.Context(), "g1", client.FirewallGroupInput{TeamID: "team-a", Description: "edge 2"})

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{{Method: "PUT", Path: "/network/firewalls/g1", Body: map[string]any{
		"team_id": "team-a", "description": "edge 2",
	}}}, ctx.api.GetRequests())
}

func TestRemoveFirewallGroupRemovesAGroupInTheTeam(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "instance_count": 0})

	err := ctx.client.RemoveFirewallGroup(t.Context(), "g1", "team-a")

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]map[string]any{},
		[]onideltest.Request{{Method: "DELETE", Path: "/network/firewalls/g1", Query: "team_id=team-a"}},
	}, []any{ctx.api.GetFirewallGroups(), ctx.api.GetRequests()})
}

func TestRemoveFirewallGroupFailsWhileVMsAreAttached(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "instance_count": 1})

	err := ctx.client.RemoveFirewallGroup(t.Context(), "g1", "")

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "DELETE", Path: "/network/firewalls/g1", Status: 400}, apiErr)
}

func TestCreateFirewallRuleDecodesTheSubnetSizeTheCreateSendsAsAString(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})

	rule, err := ctx.client.CreateFirewallRule(t.Context(), "g1", client.FirewallRuleInput{
		TeamID: "team-a", Protocol: "tcp", Port: "443", Subnet: "203.0.113.0", SubnetSize: 24, Description: "web",
	})

	require.NoError(t, err)
	assert.Equal(t, client.FirewallRule{
		ID: "00000000-0000-4000-8000-000000000001", Group: "g1", IPType: "v4", Action: "allow", Protocol: "tcp",
		Port: "443", Subnet: "203.0.113.0", SubnetSize: 24, Description: "web",
	}, rule)
}

func TestCreateFirewallRuleOmitsAnEmptyPortAndDescription(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})

	_, err := ctx.client.CreateFirewallRule(t.Context(), "g1", client.FirewallRuleInput{Protocol: "icmp", Subnet: "::", SubnetSize: 0})

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{{Method: "POST", Path: "/network/firewalls/g1/rules", Body: map[string]any{
		"protocol": "icmp", "subnet": "::", "subnet_size": 0.0,
	}}}, ctx.api.GetRequests())
}

func TestReadFirewallRuleReadsOneRuleInTheTeam(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})
	_, err := ctx.client.CreateFirewallRule(t.Context(), "g1", client.FirewallRuleInput{Protocol: "icmp", Subnet: "::", SubnetSize: 0})
	require.NoError(t, err)

	rule, err := ctx.client.ReadFirewallRule(t.Context(), "g1", "00000000-0000-4000-8000-000000000001", "team-a")

	require.NoError(t, err)
	assert.Equal(t, []any{
		client.FirewallRule{
			ID: "00000000-0000-4000-8000-000000000001", Group: "g1", IPType: "v6", Action: "allow",
			Protocol: "ipv6-icmp", Subnet: "::",
		},
		[]onideltest.Request{
			{Method: "POST", Path: "/network/firewalls/g1/rules", Body: map[string]any{"protocol": "icmp", "subnet": "::", "subnet_size": 0.0}},
			{Method: "GET", Path: "/network/firewalls/g1/rules/00000000-0000-4000-8000-000000000001", Query: "team_id=team-a"},
		},
	}, []any{rule, ctx.api.GetRequests()})
}

func TestUpdateFirewallRuleDescriptionChangesOnlyTheDescription(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})
	_, err := ctx.client.CreateFirewallRule(t.Context(), "g1", client.FirewallRuleInput{Protocol: "tcp", Port: "22", Subnet: "0.0.0.0", SubnetSize: 0})
	require.NoError(t, err)

	err = ctx.client.UpdateFirewallRuleDescription(t.Context(), "g1", "00000000-0000-4000-8000-000000000001", "team-a", "ssh")

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{
		{Method: "POST", Path: "/network/firewalls/g1/rules", Body: map[string]any{"protocol": "tcp", "port": "22", "subnet": "0.0.0.0", "subnet_size": 0.0}},
		{
			Method: "PATCH", Path: "/network/firewalls/g1/rules/00000000-0000-4000-8000-000000000001",
			Body: map[string]any{"team_id": "team-a", "desc": "ssh"},
		},
	}, ctx.api.GetRequests())
}

func TestRemoveFirewallRuleRemovesARuleInTheTeam(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})
	_, err := ctx.client.CreateFirewallRule(t.Context(), "g1", client.FirewallRuleInput{Protocol: "tcp", Port: "22", Subnet: "0.0.0.0", SubnetSize: 0})
	require.NoError(t, err)

	err = ctx.client.RemoveFirewallRule(t.Context(), "g1", "00000000-0000-4000-8000-000000000001", "team-a")

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]map[string]any{},
		[]onideltest.Request{
			{Method: "POST", Path: "/network/firewalls/g1/rules", Body: map[string]any{"protocol": "tcp", "port": "22", "subnet": "0.0.0.0", "subnet_size": 0.0}},
			{Method: "DELETE", Path: "/network/firewalls/g1/rules/00000000-0000-4000-8000-000000000001", Query: "team_id=team-a"},
		},
	}, []any{ctx.api.GetFirewallRules(), ctx.api.GetRequests()})
}
