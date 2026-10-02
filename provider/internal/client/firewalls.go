package client

import (
	"context"
	"net/http"
	"net/url"
)

// FirewallGroup is a cloud firewall group. The API identifies a group by its ID and
// labels it with a description only.
type FirewallGroup struct {
	ID            string `json:"id"`
	Description   string `json:"description"`
	Created       string `json:"created"`
	Updated       string `json:"updated"`
	InstanceCount int    `json:"instance_count"`
	RuleCount     int    `json:"rule_count"`
}

// FirewallGroupInput is the body of a create or update.
type FirewallGroupInput struct {
	TeamID      string `json:"team_id,omitempty"`
	Description string `json:"description"`
}

type firewallGroupEnvelope struct {
	FirewallGroup FirewallGroup `json:"firewall_group"`
}

func buildFirewallPath(id string) string { return "/network/firewalls/" + url.PathEscape(id) }

// CreateFirewallGroup creates a group (POST /network/firewalls).
func (c *Client) CreateFirewallGroup(ctx context.Context, in FirewallGroupInput) (FirewallGroup, error) {
	var out firewallGroupEnvelope
	_, err := c.sendRequest(ctx, http.MethodPost, "/network/firewalls", nil, in, &out)
	return out.FirewallGroup, err
}

// ReadFirewallGroup gets one group (GET /network/firewalls/{id}).
func (c *Client) ReadFirewallGroup(ctx context.Context, id string) (FirewallGroup, error) {
	var out firewallGroupEnvelope
	_, err := c.sendRequest(ctx, http.MethodGet, buildFirewallPath(id), nil, nil, &out)
	return out.FirewallGroup, err
}

// UpdateFirewallGroup changes a group's description (PUT /network/firewalls/{id}).
func (c *Client) UpdateFirewallGroup(ctx context.Context, id string, in FirewallGroupInput) error {
	_, err := c.sendRequest(ctx, http.MethodPut, buildFirewallPath(id), nil, in, nil)
	return err
}

// RemoveFirewallGroup deletes a group (DELETE /network/firewalls/{id}). The API
// refuses while VMs are attached.
func (c *Client) RemoveFirewallGroup(ctx context.Context, id, teamID string) error {
	_, err := c.sendRequest(ctx, http.MethodDelete, buildFirewallPath(id), buildTeamQuery(teamID), nil, nil)
	return err
}

// FirewallRule is one allow rule in a group.
type FirewallRule struct {
	ID          string  `json:"id"`
	Group       string  `json:"group"`
	IPType      string  `json:"ip_type"`
	Action      string  `json:"action"`
	Protocol    string  `json:"protocol"`
	Port        string  `json:"port"`
	Subnet      string  `json:"subnet"`
	SubnetSize  FlexInt `json:"subnet_size"`
	Description string  `json:"desc"`
}

// FirewallRuleInput is the body of a rule create.
type FirewallRuleInput struct {
	TeamID      string `json:"team_id,omitempty"`
	Protocol    string `json:"protocol"`
	Port        string `json:"port,omitempty"`
	Subnet      string `json:"subnet"`
	SubnetSize  int    `json:"subnet_size"`
	Description string `json:"desc,omitempty"`
}

type firewallRuleEnvelope struct {
	FirewallRule FirewallRule `json:"firewall_rule"`
}

func buildFirewallRulePath(firewallID, ruleID string) string {
	return buildFirewallPath(firewallID) + "/rules/" + url.PathEscape(ruleID)
}

// CreateFirewallRule adds a rule (POST /network/firewalls/{id}/rules).
func (c *Client) CreateFirewallRule(ctx context.Context, firewallID string, in FirewallRuleInput) (FirewallRule, error) {
	var out firewallRuleEnvelope
	_, err := c.sendRequest(ctx, http.MethodPost, buildFirewallPath(firewallID)+"/rules", nil, in, &out)
	return out.FirewallRule, err
}

// ReadFirewallRule gets one rule (GET /network/firewalls/{id}/rules/{rule_id}).
func (c *Client) ReadFirewallRule(ctx context.Context, firewallID, ruleID, teamID string) (FirewallRule, error) {
	var out firewallRuleEnvelope
	_, err := c.sendRequest(ctx, http.MethodGet, buildFirewallRulePath(firewallID, ruleID),
		buildTeamQuery(teamID), nil, &out)
	return out.FirewallRule, err
}

// UpdateFirewallRuleDescription changes a rule's description, the only mutable field
// (PATCH /network/firewalls/{id}/rules/{rule_id}).
func (c *Client) UpdateFirewallRuleDescription(ctx context.Context, firewallID, ruleID, teamID, desc string) error {
	body := struct {
		TeamID string `json:"team_id,omitempty"`
		Desc   string `json:"desc"`
	}{teamID, desc}
	_, err := c.sendRequest(ctx, http.MethodPatch, buildFirewallRulePath(firewallID, ruleID), nil, body, nil)
	return err
}

// RemoveFirewallRule deletes a rule (DELETE /network/firewalls/{id}/rules/{rule_id}).
func (c *Client) RemoveFirewallRule(ctx context.Context, firewallID, ruleID, teamID string) error {
	_, err := c.sendRequest(ctx, http.MethodDelete, buildFirewallRulePath(firewallID, ruleID),
		buildTeamQuery(teamID), nil, nil)
	return err
}
