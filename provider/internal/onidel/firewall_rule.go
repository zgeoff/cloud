package onidel

import (
	"context"
	"fmt"
	"strings"

	"github.com/pulumi/pulumi-go-provider/infer"

	"github.com/zgeoff/cloud/provider/internal/client"
)

// FirewallRule is onidel:index:FirewallRule, one allow rule in a firewall group. Its ID
// is `<firewallId>/<ruleId>`, which is also the import ID.
type FirewallRule struct{}

// FirewallRuleArgs are the FirewallRule inputs. Only description is updatable; every
// other change replaces the rule.
type FirewallRuleArgs struct {
	FirewallID  string  `pulumi:"firewallId" provider:"replaceOnChanges"`
	Protocol    string  `pulumi:"protocol" provider:"replaceOnChanges"`
	Port        *string `pulumi:"port,optional" provider:"replaceOnChanges"`
	Subnet      string  `pulumi:"subnet" provider:"replaceOnChanges"`
	SubnetSize  int     `pulumi:"subnetSize" provider:"replaceOnChanges"`
	Description *string `pulumi:"description,optional"`
}

// FirewallRuleState is the FirewallRule state.
type FirewallRuleState struct {
	FirewallRuleArgs
	RuleID string `pulumi:"ruleId"`
	IPType string `pulumi:"ipType"`
	Action string `pulumi:"action"`
}

// Annotate sets the token and docs.
func (r *FirewallRule) Annotate(a infer.Annotator) {
	a.SetToken("index", "FirewallRule")
	a.Describe(r, "An allow rule in an Onidel firewall group. Import with `<firewallId>/<ruleId>`.")
}

// Annotate documents the inputs.
func (a *FirewallRuleArgs) Annotate(an infer.Annotator) {
	an.Describe(&a.FirewallID, "ID of the FirewallGroup the rule belongs to.")
	an.Describe(&a.Protocol, "`tcp`, `udp`, `icmp` or `ipv6-icmp`. The API stores ICMP on a v6 subnet as `ipv6-icmp`.")
	an.Describe(&a.Port, "Port or range, e.g. `443` or `8000:9000`. Omit for ICMP.")
	an.Describe(&a.Subnet, "Source IP, a special value (`Cloudflare`, `Onidel`, `HetrixTools`, "+
		"`CloudFront`, `UptimeRobot`) or an IP list reference `list:<id>`.")
	an.Describe(&a.SubnetSize, "CIDR prefix length of the subnet, e.g. 0 with subnet `0.0.0.0` for anywhere.")
	an.Describe(&a.Description, "Rule description (max 255 characters). Updatable in place.")
}

// Create adds the rule.
func (FirewallRule) Create(
	ctx context.Context, req infer.CreateRequest[FirewallRuleArgs],
) (infer.CreateResponse[FirewallRuleState], error) {
	if req.DryRun {
		return infer.CreateResponse[FirewallRuleState]{Output: FirewallRuleState{FirewallRuleArgs: req.Inputs}}, nil
	}
	api, cfg := getClient(ctx)
	in := req.Inputs
	rule, err := api.CreateFirewallRule(ctx, in.FirewallID, client.FirewallRuleInput{
		TeamID:      cfg.teamID,
		Protocol:    in.Protocol,
		Port:        getOrDefault(in.Port, ""),
		Subnet:      in.Subnet,
		SubnetSize:  in.SubnetSize,
		Description: getOrDefault(in.Description, ""),
	})
	if err != nil {
		return infer.CreateResponse[FirewallRuleState]{}, err
	}
	return infer.CreateResponse[FirewallRuleState]{
		ID:     in.FirewallID + "/" + rule.ID,
		Output: buildFirewallRuleState(in, in.FirewallID, rule),
	}, nil
}

// Read refreshes or imports the rule.
func (FirewallRule) Read(
	ctx context.Context, req infer.ReadRequest[FirewallRuleArgs, FirewallRuleState],
) (infer.ReadResponse[FirewallRuleArgs, FirewallRuleState], error) {
	firewallID, ruleID, err := splitFirewallRuleID(req.ID)
	if err != nil {
		return infer.ReadResponse[FirewallRuleArgs, FirewallRuleState]{}, err
	}
	api, cfg := getClient(ctx)
	rule, err := api.ReadFirewallRule(ctx, firewallID, ruleID, cfg.teamID)
	if client.IsNotFound(err) {
		return infer.ReadResponse[FirewallRuleArgs, FirewallRuleState]{}, nil
	}
	if err != nil {
		return infer.ReadResponse[FirewallRuleArgs, FirewallRuleState]{}, err
	}
	state := buildFirewallRuleState(req.Inputs, firewallID, rule)
	return infer.ReadResponse[FirewallRuleArgs, FirewallRuleState]{
		ID: req.ID, Inputs: state.FirewallRuleArgs, State: state,
	}, nil
}

// Update changes the description, the only field the API can change.
func (FirewallRule) Update(
	ctx context.Context, req infer.UpdateRequest[FirewallRuleArgs, FirewallRuleState],
) (infer.UpdateResponse[FirewallRuleState], error) {
	next := req.State
	next.FirewallRuleArgs = req.Inputs
	if req.DryRun {
		return infer.UpdateResponse[FirewallRuleState]{Output: next}, nil
	}
	firewallID, ruleID, err := splitFirewallRuleID(req.ID)
	if err != nil {
		return infer.UpdateResponse[FirewallRuleState]{}, err
	}
	api, cfg := getClient(ctx)
	err = api.UpdateFirewallRuleDescription(ctx, firewallID, ruleID, cfg.teamID, getOrDefault(req.Inputs.Description, ""))
	if err != nil {
		return infer.UpdateResponse[FirewallRuleState]{}, err
	}
	return infer.UpdateResponse[FirewallRuleState]{Output: next}, nil
}

// Delete removes the rule.
func (FirewallRule) Delete(ctx context.Context, req infer.DeleteRequest[FirewallRuleState]) (infer.DeleteResponse, error) {
	firewallID, ruleID, err := splitFirewallRuleID(req.ID)
	if err != nil {
		return infer.DeleteResponse{}, err
	}
	api, cfg := getClient(ctx)
	err = api.RemoveFirewallRule(ctx, firewallID, ruleID, cfg.teamID)
	if client.IsNotFound(err) {
		err = nil
	}
	return infer.DeleteResponse{}, err
}

// FirewallRuleIDError is a FirewallRule ID that is not `<firewallId>/<ruleId>`.
type FirewallRuleIDError struct {
	ID string
}

func (e *FirewallRuleIDError) Error() string {
	return fmt.Sprintf("onidel: firewall rule ID %q is not <firewallId>/<ruleId>", e.ID)
}

func splitFirewallRuleID(id string) (string, string, error) {
	firewallID, ruleID, ok := strings.Cut(id, "/")
	if !ok || firewallID == "" || ruleID == "" {
		return "", "", &FirewallRuleIDError{ID: id}
	}
	return firewallID, ruleID, nil
}

// buildFirewallRuleState maps an API rule to state, keeping the program's spelling
// where the API normalizes an equivalent value (ICMP naming, an empty port).
func buildFirewallRuleState(in FirewallRuleArgs, firewallID string, rule client.FirewallRule) FirewallRuleState {
	protocol := rule.Protocol
	if in.Protocol == "icmp" && rule.Protocol == "ipv6-icmp" {
		protocol = in.Protocol
	}

	var port *string
	if rule.Port != "" {
		port = &rule.Port
	}
	if in.Port == nil && (rule.Port == "" || isICMP(rule.Protocol)) {
		port = nil
	}

	var desc *string
	if rule.Description != "" {
		desc = &rule.Description
	}

	return FirewallRuleState{
		FirewallRuleArgs: FirewallRuleArgs{
			FirewallID:  firewallID,
			Protocol:    protocol,
			Port:        port,
			Subnet:      rule.Subnet,
			SubnetSize:  int(rule.SubnetSize),
			Description: desc,
		},
		RuleID: rule.ID,
		IPType: rule.IPType,
		Action: rule.Action,
	}
}

func isICMP(protocol string) bool { return protocol == "icmp" || protocol == "ipv6-icmp" }

func getOrDefault[T any](v *T, fallback T) T {
	if v == nil {
		return fallback
	}
	return *v
}
