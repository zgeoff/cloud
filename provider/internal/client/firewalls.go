package client

import (
	"context"

	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

// CreateFirewallGroup creates a group (POST /network/firewalls).
func (c *Client) CreateFirewallGroup(ctx context.Context, in onidelapi.NewFirewallGroup) (onidelapi.FirewallGroup, error) {
	out, err := decodeResponse[onidelapi.FirewallGroupDetail](c.api.CreateFirewall(ctx, in))
	return out.FirewallGroup, err
}

// ReadFirewallGroup gets one group (GET /network/firewalls/{id}).
func (c *Client) ReadFirewallGroup(ctx context.Context, id string) (onidelapi.FirewallGroup, error) {
	out, err := decodeResponse[onidelapi.FirewallGroupDetail](c.api.GetFirewall(ctx, id))
	return out.FirewallGroup, err
}

// UpdateFirewallGroup changes a group's description (PUT /network/firewalls/{id}).
func (c *Client) UpdateFirewallGroup(ctx context.Context, id string, in onidelapi.UpdateFirewallGroup) error {
	return requireSuccess(c.api.UpdateFirewall(ctx, id, in))
}

// RemoveFirewallGroup deletes a group (DELETE /network/firewalls/{id}). The API
// refuses while VMs are attached.
func (c *Client) RemoveFirewallGroup(ctx context.Context, id, teamID string) error {
	return requireSuccess(c.api.DeleteFirewall(ctx, id, &onidelapi.DeleteFirewallParams{TeamID: buildTeamID(teamID)}))
}

// CreateFirewallRule adds a rule (POST /network/firewalls/{id}/rules).
func (c *Client) CreateFirewallRule(ctx context.Context, firewallID string, in onidelapi.NewFirewallRule) (onidelapi.FirewallRule, error) {
	out, err := decodeResponse[onidelapi.FirewallRuleResponse](c.api.CreateFirewallRule(ctx, firewallID, in))
	return out.FirewallRule, err
}

// ReadFirewallRule gets one rule (GET /network/firewalls/{id}/rules/{rule_id}).
func (c *Client) ReadFirewallRule(ctx context.Context, firewallID, ruleID, teamID string) (onidelapi.FirewallRule, error) {
	out, err := decodeResponse[onidelapi.FirewallRuleResponse](c.api.GetFirewallRule(ctx, firewallID, ruleID,
		&onidelapi.GetFirewallRuleParams{TeamID: buildTeamID(teamID)}))
	return out.FirewallRule, err
}

// UpdateFirewallRuleDescription changes a rule's description, the only mutable field
// (PATCH /network/firewalls/{id}/rules/{rule_id}).
func (c *Client) UpdateFirewallRuleDescription(ctx context.Context, firewallID, ruleID, teamID, desc string) error {
	return requireSuccess(c.api.UpdateFirewallRule(ctx, firewallID, ruleID,
		onidelapi.UpdateFirewallRuleJSONRequestBody{TeamID: teamID, Desc: desc}))
}

// RemoveFirewallRule deletes a rule (DELETE /network/firewalls/{id}/rules/{rule_id}).
func (c *Client) RemoveFirewallRule(ctx context.Context, firewallID, ruleID, teamID string) error {
	return requireSuccess(c.api.DeleteFirewallRule(ctx, firewallID, ruleID,
		&onidelapi.DeleteFirewallRuleParams{TeamID: buildTeamID(teamID)}))
}
