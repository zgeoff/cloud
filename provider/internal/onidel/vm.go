package onidel

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	p "github.com/pulumi/pulumi-go-provider"
	"github.com/pulumi/pulumi-go-provider/infer"

	"github.com/zgeoff/cloud/provider/internal/client"
)

// VM is onidel:index:Vm, a virtual machine.
//
// The API's VM object carries the root password; the client drops it at decode time,
// so it never reaches state.
type VM struct{}

// VMArgs are the Vm inputs.
//
// name, ipv6 and firewallGroupId update in place through PATCH. Every other input
// replaces the VM: the API cannot change them after provisioning.
//
// The API does not report os directly (it is resolved from the template name),
// instanceType, paymentCycle, snapshotId, isoId, sshKeys, vpcs, startupScriptId or
// disableSshBlocking. Read keeps their prior values, and an imported VM adopts the
// program's values for them without a replace.
type VMArgs struct {
	Name     string `pulumi:"name"`
	Location string `pulumi:"location" provider:"replaceOnChanges"`
	CPU      int    `pulumi:"cpu" provider:"replaceOnChanges"`
	RAM      int    `pulumi:"ram" provider:"replaceOnChanges"`
	Disk     int    `pulumi:"disk" provider:"replaceOnChanges"`

	OS                 *int     `pulumi:"os,optional" provider:"replaceOnChanges"`
	SnapshotID         *string  `pulumi:"snapshotId,optional" provider:"replaceOnChanges"`
	ISOID              *string  `pulumi:"isoId,optional" provider:"replaceOnChanges"`
	InstanceType       *string  `pulumi:"instanceType,optional" provider:"replaceOnChanges"`
	PaymentCycle       *string  `pulumi:"paymentCycle,optional" provider:"replaceOnChanges"`
	SSHKeys            []string `pulumi:"sshKeys,optional" provider:"replaceOnChanges"`
	VPCs               []string `pulumi:"vpcs,optional" provider:"replaceOnChanges"`
	StartupScriptID    *string  `pulumi:"startupScriptId,optional" provider:"replaceOnChanges"`
	DisableSSHBlocking *bool    `pulumi:"disableSshBlocking,optional" provider:"replaceOnChanges"`

	IPv6            *bool   `pulumi:"ipv6,optional"`
	FirewallGroupID *string `pulumi:"firewallGroupId,optional"`
}

// VMState is the Vm state. It has no password field, by design.
type VMState struct {
	VMArgs
	Status     string `pulumi:"status"`
	MainIPv4   string `pulumi:"mainIpv4"`
	MainIPv6   string `pulumi:"mainIpv6"`
	Template   string `pulumi:"template"`
	BGPEnabled bool   `pulumi:"bgpEnabled"`
	CreatedAt  string `pulumi:"createdAt"`
}

// Annotate sets the token and docs.
func (v *VM) Annotate(a infer.Annotator) {
	a.SetToken("index", "Vm")
	a.Describe(v, "An Onidel virtual machine. Import an existing one with its UUID: "+
		"`pulumi import onidel:index:Vm <name> <vm-id>`.")
}

// Annotate documents the inputs.
func (a *VMArgs) Annotate(an infer.Annotator) {
	an.Describe(&a.Name, "Hostname and display name. Updatable in place.")
	an.Describe(&a.Location, "Location, e.g. `Melbourne`. Replaces the VM.")
	an.Describe(&a.CPU, "vCPU count. Replaces the VM: the API has no resize.")
	an.Describe(&a.RAM, "RAM in MB. Replaces the VM.")
	an.Describe(&a.Disk, "Root disk in GB. Replaces the VM.")
	an.Describe(&a.OS, "OS template ID (see GET /os_templates). Provide one of os, snapshotId or isoId. "+
		"Replaces the VM.")
	an.Describe(&a.SnapshotID, "Snapshot to deploy from. Replaces the VM.")
	an.Describe(&a.ISOID, "Custom or system ISO to boot from. Replaces the VM.")
	an.Describe(&a.InstanceType, "Instance type UUID. Replaces the VM.")
	an.Describe(&a.PaymentCycle, "Billing cycle: hourly, monthly, quarterly, semiannually, annually, "+
		"biennially or triennially. Replaces the VM.")
	an.Describe(&a.SSHKeys, "SshKey IDs installed at provisioning. Replaces the VM.")
	an.Describe(&a.VPCs, "VPC IDs to attach at provisioning. Replaces the VM.")
	an.Describe(&a.StartupScriptID, "Startup script run on first boot. Replaces the VM.")
	an.Describe(&a.DisableSSHBlocking, "Allow outbound SSH (port 22). Replaces the VM.")
	an.Describe(&a.IPv6, "Enable IPv6. Updatable in place; unset leaves it as the API has it.")
	an.Describe(&a.FirewallGroupID, "FirewallGroup to attach. Updatable in place; unset detaches.")
}

// Create provisions the VM and waits until it is active.
func (VM) Create(ctx context.Context, req infer.CreateRequest[VMArgs]) (infer.CreateResponse[VMState], error) {
	in := req.Inputs
	if n := countSet(in.OS != nil, in.SnapshotID != nil, in.ISOID != nil); n != 1 {
		return infer.CreateResponse[VMState]{}, errors.New("onidel: a Vm needs exactly one of os, snapshotId or isoId")
	}
	if req.DryRun {
		return infer.CreateResponse[VMState]{Output: VMState{VMArgs: in}}, nil
	}

	api, cfg := getClient(ctx)
	vm, err := api.CreateVM(ctx, client.VMInput{
		TeamID:             cfg.teamID,
		Name:               in.Name,
		PaymentCycle:       getOrDefault(in.PaymentCycle, ""),
		InstanceType:       getOrDefault(in.InstanceType, ""),
		Location:           in.Location,
		CPU:                in.CPU,
		RAM:                in.RAM,
		Disk:               in.Disk,
		OS:                 in.OS,
		SnapshotID:         getOrDefault(in.SnapshotID, ""),
		ISOID:              getOrDefault(in.ISOID, ""),
		SSHKeys:            in.SSHKeys,
		VPCs:               in.VPCs,
		FirewallGroupID:    getOrDefault(in.FirewallGroupID, ""),
		IPv6:               getOrDefault(in.IPv6, false),
		DisableSSHBlocking: getOrDefault(in.DisableSSHBlocking, false),
		StartupScriptID:    getOrDefault(in.StartupScriptID, ""),
	})
	if err != nil && vm.ID != "" {
		// Created but never became ready: keep it in state so it is not leaked.
		return infer.CreateResponse[VMState]{ID: vm.ID, Output: VMState{VMArgs: in}},
			infer.ResourceInitFailedError{Reasons: []string{err.Error()}}
	}
	if err != nil {
		return infer.CreateResponse[VMState]{}, err
	}
	return infer.CreateResponse[VMState]{ID: vm.ID, Output: buildVMState(in, vm)}, nil
}

// Read refreshes the VM, or adopts one by ID for `pulumi import`.
func (VM) Read(ctx context.Context, req infer.ReadRequest[VMArgs, VMState]) (infer.ReadResponse[VMArgs, VMState], error) {
	api, cfg := getClient(ctx)
	vm, err := api.ReadVM(ctx, req.ID, cfg.teamID)
	if client.IsNotFound(err) {
		return infer.ReadResponse[VMArgs, VMState]{}, nil
	}
	if err != nil {
		return infer.ReadResponse[VMArgs, VMState]{}, err
	}

	// Start from the prior inputs so the fields the API does not report survive.
	args := req.Inputs
	isImport := args.Name == "" && args.Location == ""
	args.Name = vm.Name
	args.Location = vm.Location
	args.CPU = vm.VCPU
	args.RAM = vm.RAM
	args.Disk = vm.Disk
	args.FirewallGroupID = nil
	if vm.FirewallGroupID != "" {
		id := string(vm.FirewallGroupID)
		args.FirewallGroupID = &id
	}
	if args.IPv6 != nil || isImport {
		enabled := vm.MainIPv6 != ""
		args.IPv6 = &enabled
	}
	if args.SnapshotID == nil && args.ISOID == nil && vm.Template != "" {
		osID, err := findOSTemplateID(ctx, api, vm.Template)
		if err != nil {
			return infer.ReadResponse[VMArgs, VMState]{}, err
		}
		if osID != nil {
			args.OS = osID
		}
	}

	return infer.ReadResponse[VMArgs, VMState]{ID: vm.ID, Inputs: args, State: buildVMState(args, vm)}, nil
}

// Diff reports which inputs changed and which of those replace the VM.
//
// It is custom for one reason: an imported VM has no prior value for the inputs the
// API does not report, so a program that sets them must adopt them rather than
// replace the VM. Those inputs replace only when both the old and new value are set
// and differ.
func (VM) Diff(_ context.Context, req infer.DiffRequest[VMArgs, VMState]) (p.DiffResponse, error) {
	old, next := req.State.VMArgs, req.Inputs
	d := map[string]p.PropertyDiff{}

	addValueDiff(d, "name", old.Name, next.Name, false)
	if !strings.EqualFold(old.Location, next.Location) {
		addValueDiff(d, "location", old.Location, next.Location, true)
	}
	addValueDiff(d, "cpu", old.CPU, next.CPU, true)
	addValueDiff(d, "ram", old.RAM, next.RAM, true)
	addValueDiff(d, "disk", old.Disk, next.Disk, true)

	addCreateOnlyDiff(d, "os", old.OS, next.OS)
	addCreateOnlyDiff(d, "snapshotId", old.SnapshotID, next.SnapshotID)
	addCreateOnlyDiff(d, "isoId", old.ISOID, next.ISOID)
	addCreateOnlyDiff(d, "instanceType", old.InstanceType, next.InstanceType)
	addCreateOnlyDiff(d, "paymentCycle", old.PaymentCycle, next.PaymentCycle)
	addCreateOnlyDiff(d, "startupScriptId", old.StartupScriptID, next.StartupScriptID)
	addCreateOnlyDiff(d, "disableSshBlocking", old.DisableSSHBlocking, next.DisableSSHBlocking)
	addCreateOnlySetDiff(d, "sshKeys", old.SSHKeys, next.SSHKeys)
	addCreateOnlySetDiff(d, "vpcs", old.VPCs, next.VPCs)

	if next.IPv6 != nil && (old.IPv6 == nil || *old.IPv6 != *next.IPv6) {
		d["ipv6"] = p.PropertyDiff{Kind: p.Update, InputDiff: true}
	}
	addValueDiff(d, "firewallGroupId", getOrDefault(old.FirewallGroupID, ""),
		getOrDefault(next.FirewallGroupID, ""), false)

	return p.DiffResponse{HasChanges: len(d) > 0, DetailedDiff: d}, nil
}

// Update applies the in-place changes, one PATCH each, waiting for the VM to settle
// between them.
func (VM) Update(ctx context.Context, req infer.UpdateRequest[VMArgs, VMState]) (infer.UpdateResponse[VMState], error) {
	old, next := req.State.VMArgs, req.Inputs
	if req.DryRun {
		state := req.State
		state.VMArgs = next
		return infer.UpdateResponse[VMState]{Output: state}, nil
	}

	api, cfg := getClient(ctx)
	patches := planVMPatches(old, next, cfg.teamID)
	vm, err := api.ReadVM(ctx, req.ID, cfg.teamID)
	for _, patch := range patches {
		if err != nil {
			break
		}
		vm, err = api.UpdateVM(ctx, req.ID, patch)
	}
	if err != nil {
		return infer.UpdateResponse[VMState]{}, err
	}
	return infer.UpdateResponse[VMState]{Output: buildVMState(next, vm)}, nil
}

// Delete destroys the VM and waits until it is gone.
func (VM) Delete(ctx context.Context, req infer.DeleteRequest[VMState]) (infer.DeleteResponse, error) {
	api, cfg := getClient(ctx)
	return infer.DeleteResponse{}, api.RemoveVM(ctx, req.ID, cfg.teamID)
}

// planVMPatches turns an input change into the PATCH actions that apply it.
func planVMPatches(old, next VMArgs, teamID string) []client.VMPatch {
	var patches []client.VMPatch
	if next.Name != old.Name {
		patches = append(patches, client.VMPatch{TeamID: teamID, Name: next.Name})
	}
	if next.IPv6 != nil && (old.IPv6 == nil || *old.IPv6 != *next.IPv6) {
		patches = append(patches, client.VMPatch{TeamID: teamID, EnableIPv6: next.IPv6})
	}
	oldFirewall, nextFirewall := getOrDefault(old.FirewallGroupID, ""), getOrDefault(next.FirewallGroupID, "")
	switch {
	case nextFirewall == oldFirewall:
	case nextFirewall == "":
		detach := true
		patches = append(patches, client.VMPatch{TeamID: teamID, DisableFirewall: &detach})
	default:
		patches = append(patches, client.VMPatch{TeamID: teamID, FirewallGroupID: nextFirewall})
	}
	return patches
}

// buildVMState maps an API VM onto state. Only the listed fields are copied; there is
// no password to copy.
func buildVMState(args VMArgs, vm client.VM) VMState {
	return VMState{
		VMArgs:     args,
		Status:     vm.Status,
		MainIPv4:   vm.MainIPv4,
		MainIPv6:   vm.MainIPv6,
		Template:   vm.Template,
		BGPEnabled: vm.BGPEnabled,
		CreatedAt:  vm.CreatedAt,
	}
}

// findOSTemplateID resolves a template name, as GET /vm reports it, to its ID.
func findOSTemplateID(ctx context.Context, api *client.Client, name string) (*int, error) {
	templates, err := api.ReadOSTemplates(ctx)
	if err != nil {
		return nil, fmt.Errorf("onidel: resolve the VM's OS template: %w", err)
	}
	for _, t := range templates {
		if t.Name == name {
			id := t.ID
			return &id, nil
		}
	}
	return nil, nil
}

func countSet(flags ...bool) int {
	n := 0
	for _, f := range flags {
		if f {
			n++
		}
	}
	return n
}

// addValueDiff records a change to a plain input.
func addValueDiff[T comparable](d map[string]p.PropertyDiff, key string, old, next T, replace bool) {
	if old == next {
		return
	}
	var zero T
	kind := p.Update
	switch {
	case old == zero:
		kind = p.Add
	case next == zero:
		kind = p.Delete
	}
	if replace {
		kind = toReplaceKind(kind)
	}
	d[key] = p.PropertyDiff{Kind: kind, InputDiff: true}
}

// addCreateOnlyDiff records a change to an input the API cannot report or change:
// it replaces only when both sides are set and differ.
func addCreateOnlyDiff[T comparable](d map[string]p.PropertyDiff, key string, old, next *T) {
	if old == nil || next == nil || *old == *next {
		return
	}
	d[key] = p.PropertyDiff{Kind: p.UpdateReplace, InputDiff: true}
}

// addCreateOnlySetDiff is addCreateOnlyDiff for an unordered list of IDs.
func addCreateOnlySetDiff(d map[string]p.PropertyDiff, key string, old, next []string) {
	if old == nil || next == nil {
		return
	}
	a, b := slices.Clone(old), slices.Clone(next)
	slices.Sort(a)
	slices.Sort(b)
	if slices.Equal(a, b) {
		return
	}
	d[key] = p.PropertyDiff{Kind: p.UpdateReplace, InputDiff: true}
}

func toReplaceKind(kind p.DiffKind) p.DiffKind {
	switch kind {
	case p.Add:
		return p.AddReplace
	case p.Delete:
		return p.DeleteReplace
	default:
		return p.UpdateReplace
	}
}
