package onidel

import (
	"context"

	"github.com/pulumi/pulumi-go-provider/infer"

	"github.com/zgeoff/cloud/provider/internal/client"
)

// FirewallGroup is onidel:index:FirewallGroup, a cloud firewall group. Attach it to a
// VM with the Vm's firewallGroupId.
type FirewallGroup struct{}

// FirewallGroupArgs are the FirewallGroup inputs.
type FirewallGroupArgs struct {
	Description string `pulumi:"description"`
}

// FirewallGroupState is the FirewallGroup state.
type FirewallGroupState struct {
	FirewallGroupArgs
	Created       string `pulumi:"created"`
	Updated       string `pulumi:"updated"`
	InstanceCount int    `pulumi:"instanceCount"`
	RuleCount     int    `pulumi:"ruleCount"`
}

// Annotate sets the token and docs.
func (g *FirewallGroup) Annotate(a infer.Annotator) {
	a.SetToken("index", "FirewallGroup")
	a.Describe(g, "An Onidel cloud firewall group. Rules are FirewallRule resources; "+
		"attach the group to a VM with the Vm's firewallGroupId.")
}

// Annotate documents the inputs.
func (a *FirewallGroupArgs) Annotate(an infer.Annotator) {
	an.Describe(&a.Description, "The group's label (max 255 characters). Updatable in place.")
}

// Create creates the group.
func (FirewallGroup) Create(
	ctx context.Context, req infer.CreateRequest[FirewallGroupArgs],
) (infer.CreateResponse[FirewallGroupState], error) {
	if req.DryRun {
		return infer.CreateResponse[FirewallGroupState]{Output: FirewallGroupState{FirewallGroupArgs: req.Inputs}}, nil
	}
	api, cfg := getClient(ctx)
	group, err := api.CreateFirewallGroup(ctx, client.FirewallGroupInput{
		TeamID: cfg.TeamID, Description: req.Inputs.Description,
	})
	if err != nil {
		return infer.CreateResponse[FirewallGroupState]{}, err
	}
	return infer.CreateResponse[FirewallGroupState]{ID: group.ID, Output: buildFirewallGroupState(group)}, nil
}

// Read refreshes or imports the group.
func (FirewallGroup) Read(
	ctx context.Context, req infer.ReadRequest[FirewallGroupArgs, FirewallGroupState],
) (infer.ReadResponse[FirewallGroupArgs, FirewallGroupState], error) {
	api, _ := getClient(ctx)
	group, err := api.ReadFirewallGroup(ctx, req.ID)
	if client.IsNotFound(err) {
		return infer.ReadResponse[FirewallGroupArgs, FirewallGroupState]{}, nil
	}
	if err != nil {
		return infer.ReadResponse[FirewallGroupArgs, FirewallGroupState]{}, err
	}
	state := buildFirewallGroupState(group)
	return infer.ReadResponse[FirewallGroupArgs, FirewallGroupState]{
		ID: group.ID, Inputs: state.FirewallGroupArgs, State: state,
	}, nil
}

// Update changes the description (PUT).
func (FirewallGroup) Update(
	ctx context.Context, req infer.UpdateRequest[FirewallGroupArgs, FirewallGroupState],
) (infer.UpdateResponse[FirewallGroupState], error) {
	next := req.State
	next.FirewallGroupArgs = req.Inputs
	if req.DryRun {
		return infer.UpdateResponse[FirewallGroupState]{Output: next}, nil
	}
	api, cfg := getClient(ctx)
	err := api.UpdateFirewallGroup(ctx, req.ID, client.FirewallGroupInput{
		TeamID: cfg.TeamID, Description: req.Inputs.Description,
	})
	if err != nil {
		return infer.UpdateResponse[FirewallGroupState]{}, err
	}
	group, err := api.ReadFirewallGroup(ctx, req.ID)
	if err != nil {
		return infer.UpdateResponse[FirewallGroupState]{}, err
	}
	return infer.UpdateResponse[FirewallGroupState]{Output: buildFirewallGroupState(group)}, nil
}

// Delete removes the group. The API refuses while VMs are attached.
func (FirewallGroup) Delete(
	ctx context.Context, req infer.DeleteRequest[FirewallGroupState],
) (infer.DeleteResponse, error) {
	api, cfg := getClient(ctx)
	err := api.RemoveFirewallGroup(ctx, req.ID, cfg.TeamID)
	if client.IsNotFound(err) {
		err = nil
	}
	return infer.DeleteResponse{}, err
}

func buildFirewallGroupState(group client.FirewallGroup) FirewallGroupState {
	return FirewallGroupState{
		FirewallGroupArgs: FirewallGroupArgs{Description: group.Description},
		Created:           group.Created,
		Updated:           group.Updated,
		InstanceCount:     group.InstanceCount,
		RuleCount:         group.RuleCount,
	}
}
