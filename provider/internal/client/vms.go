package client

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
)

// VM is a virtual machine as the API reports it.
//
// SECURITY: the API's VM object carries the root password in plain text under
// `password`. VM deliberately has no field for it, so encoding/json drops it at decode
// time. Do not add one, and do not decode a VM into a map.
type VM struct {
	ID              string     `json:"id"`
	Name            string     `json:"name"`
	VCPU            int        `json:"vcpu"`
	RAM             int        `json:"ram"`
	Disk            int        `json:"disk"`
	Location        string     `json:"location"`
	MainIPv4        string     `json:"main_ipv4"`
	MainIPv6        string     `json:"main_ipv6"`
	Template        string     `json:"template"`
	FirewallGroupID FlexString `json:"firewall_group_id"`
	BGPEnabled      bool       `json:"bgp_enabled"`
	Status          string     `json:"status"`
	CreatedAt       string     `json:"created_at"`
	// ActiveActionID is non-null while an async action (rename, firewall attach, ...)
	// runs; its type is undocumented, so it is kept opaque.
	ActiveActionID json.RawMessage `json:"active_action_id"`
}

// hasActiveAction reports whether an async action is still running on the VM.
func (vm VM) hasActiveAction() bool {
	return len(vm.ActiveActionID) > 0 && string(vm.ActiveActionID) != "null"
}

// VMInput is the body of POST /vm.
type VMInput struct {
	TeamID             string   `json:"team_id,omitempty"`
	Name               string   `json:"name"`
	PaymentCycle       string   `json:"payment_cycle,omitempty"`
	InstanceType       string   `json:"instance_type,omitempty"`
	Location           string   `json:"location"`
	CPU                int      `json:"cpu"`
	RAM                int      `json:"ram"`
	Disk               int      `json:"disk"`
	OS                 *int     `json:"os,omitempty"`
	SnapshotID         string   `json:"snapshot_id,omitempty"`
	ISOID              string   `json:"iso_id,omitempty"`
	SSHKeys            []string `json:"ssh_keys,omitempty"`
	VPCs               []string `json:"vpcs,omitempty"`
	FirewallGroupID    string   `json:"firewall_group_id,omitempty"`
	IPv6               bool     `json:"ipv6"`
	DisableSSHBlocking bool     `json:"disable_ssh_blocking,omitempty"`
	StartupScriptID    string   `json:"startup_script_id,omitempty"`
}

// VMPatch is one PATCH /vm/{id} action. The API takes exactly one setting per request,
// so set exactly one field.
type VMPatch struct {
	TeamID          string `json:"team_id,omitempty"`
	Name            string `json:"name,omitempty"`
	EnableIPv6      *bool  `json:"enable_ipv6,omitempty"`
	FirewallGroupID string `json:"firewall_group_id,omitempty"`
	DisableFirewall *bool  `json:"disable_firewall,omitempty"`
}

func buildVMPath(id string) string { return "/vm/" + url.PathEscape(id) }

// ReadVMs lists the team's VMs (GET /vm).
func (c *Client) ReadVMs(ctx context.Context, teamID string) ([]VM, error) {
	var vms []VM
	_, err := c.sendRequest(ctx, http.MethodGet, "/vm", buildTeamQuery(teamID), nil, &vms)
	return vms, err
}

// ReadVM gets one VM (GET /vm/{id}).
func (c *Client) ReadVM(ctx context.Context, id, teamID string) (VM, error) {
	var vm VM
	_, err := c.sendRequest(ctx, http.MethodGet, buildVMPath(id), buildTeamQuery(teamID), nil, &vm)
	return vm, err
}

// CreateVM provisions a VM and returns it once the API reports it active. When the VM
// was created but never became ready, the returned VM carries only its ID, alongside
// the error.
//
// POST /vm is documented as 201 with no body, so the new ID is taken from the body if
// one carries it, and otherwise found by listing: the VM with the requested name that
// was not there before the POST.
func (c *Client) CreateVM(ctx context.Context, in VMInput) (VM, error) {
	before, err := c.ReadVMs(ctx, in.TeamID)
	if err != nil {
		return VM{}, err
	}
	existing := make(map[string]bool, len(before))
	for _, vm := range before {
		existing[vm.ID] = true
	}

	raw, err := c.sendRequest(ctx, http.MethodPost, "/vm", nil, in, nil)
	if err != nil {
		return VM{}, err
	}

	id := findCreatedID(raw)
	if id == "" {
		err = c.waitFor(ctx, c.VMWaitTimeout, func(ctx context.Context) (bool, error) {
			vms, err := c.ReadVMs(ctx, in.TeamID)
			if err != nil {
				return false, err
			}
			id = findNewVM(vms, existing, in.Name)
			return id != "", nil
		})
		if err != nil {
			return VM{}, fmt.Errorf("onidel: find the VM %q after create: %w", in.Name, err)
		}
	}

	vm, err := c.WaitForVMReady(ctx, id, in.TeamID)
	if err != nil {
		return VM{ID: id}, err
	}
	return vm, nil
}

// findCreatedID reads an ID out of an undocumented create body, if there is one. It
// decodes only ID fields, so anything else in the body is dropped.
func findCreatedID(raw []byte) string {
	var body struct {
		ID   string `json:"id"`
		VMID string `json:"vm_id"`
		VM   struct {
			ID string `json:"id"`
		} `json:"vm"`
	}
	if json.Unmarshal(raw, &body) != nil {
		return ""
	}
	for _, id := range []string{body.ID, body.VMID, body.VM.ID} {
		if id != "" {
			return id
		}
	}
	return ""
}

// findNewVM picks the newest VM named name whose ID is not in existing.
func findNewVM(vms []VM, existing map[string]bool, name string) string {
	var found VM
	for _, vm := range vms {
		if existing[vm.ID] || vm.Name != name {
			continue
		}
		if found.ID == "" || vm.CreatedAt > found.CreatedAt {
			found = vm
		}
	}
	return found.ID
}

// UpdateVM applies one PATCH action and waits for the VM to settle.
func (c *Client) UpdateVM(ctx context.Context, id string, patch VMPatch) (VM, error) {
	if _, err := c.WaitForVMReady(ctx, id, patch.TeamID); err != nil {
		return VM{}, err
	}
	if _, err := c.sendRequest(ctx, http.MethodPatch, buildVMPath(id), nil, patch, nil); err != nil {
		return VM{}, err
	}
	return c.WaitForVMReady(ctx, id, patch.TeamID)
}

// RemoveVM destroys a VM (DELETE /vm/{id}) and waits until the API stops returning it.
// A VM that is already gone is not an error.
func (c *Client) RemoveVM(ctx context.Context, id, teamID string) error {
	_, err := c.sendRequest(ctx, http.MethodDelete, buildVMPath(id), buildTeamQuery(teamID), nil, nil)
	if IsNotFound(err) {
		return nil
	}
	if err != nil {
		return err
	}
	return c.waitFor(ctx, c.VMWaitTimeout, func(ctx context.Context) (bool, error) {
		vm, err := c.ReadVM(ctx, id, teamID)
		if IsNotFound(err) {
			return true, nil
		}
		// Undocumented: a destroyed VM may stay listed under a terminal status.
		return err == nil && goneVMStatuses[vm.Status], err
	})
}

// VM statuses that mean the VM is destroyed, should the API keep listing it.
var goneVMStatuses = map[string]bool{"terminated": true, "deleted": true, "destroyed": true}

// VM statuses that settle into active on their own.
var transientVMStatuses = map[string]bool{
	"building":        true,
	"restoring":       true,
	"migrating":       true,
	"taking_snaphot":  true, // sic: the API's spelling
	"taking_snapshot": true,
}

// VMStatusError is a VM in a status that never settles into active on its own, such
// as suspended or awaiting_payment.
type VMStatusError struct {
	ID     string
	Status string
}

func (e *VMStatusError) Error() string {
	return fmt.Sprintf("onidel: VM %s is %q, not active", e.ID, e.Status)
}

// WaitForVMReady polls until the VM is active with no action in flight.
func (c *Client) WaitForVMReady(ctx context.Context, id, teamID string) (VM, error) {
	var vm VM
	err := c.waitFor(ctx, c.VMWaitTimeout, func(ctx context.Context) (bool, error) {
		var err error
		vm, err = c.ReadVM(ctx, id, teamID)
		if err != nil {
			return false, err
		}
		if vm.Status == "active" {
			return !vm.hasActiveAction(), nil
		}
		if transientVMStatuses[vm.Status] {
			return false, nil
		}
		return false, &VMStatusError{ID: id, Status: vm.Status}
	})
	return vm, err
}
