package client

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

// hasActiveAction reports whether an async action is still running on the VM.
func hasActiveAction(vm onidelapi.VM) bool {
	return len(vm.ActiveActionID) > 0 && string(vm.ActiveActionID) != "null"
}

// ReadVMs lists the team's VMs (GET /vm).
func (c *Client) ReadVMs(ctx context.Context, teamID string) ([]onidelapi.VM, error) {
	return decodeResponse[[]onidelapi.VM](c.api.GetVMs(ctx, &onidelapi.GetVMsParams{TeamID: buildTeamID(teamID)}))
}

// ReadVM gets one VM (GET /vm/{id}).
func (c *Client) ReadVM(ctx context.Context, id, teamID string) (onidelapi.VM, error) {
	return decodeResponse[onidelapi.VM](c.api.GetVM(ctx, id, &onidelapi.GetVMParams{TeamID: buildTeamID(teamID)}))
}

// CreateVM provisions a VM and returns it once the API reports it active. When the VM
// was created but never became ready, the returned VM carries only its ID, alongside
// the error.
//
// POST /vm is documented as 201 with no body, so the new ID is taken from the body if
// one carries it, and otherwise found by listing: the VM with the requested name that
// was not there before the POST.
func (c *Client) CreateVM(ctx context.Context, in onidelapi.NewVM) (onidelapi.VM, error) {
	before, err := c.ReadVMs(ctx, in.TeamID)
	if err != nil {
		return onidelapi.VM{}, err
	}
	existing := make(map[string]bool, len(before))
	for _, vm := range before {
		existing[vm.ID] = true
	}

	raw, err := readBody(c.api.ProvisionVM(ctx, in))
	if err != nil {
		return onidelapi.VM{}, err
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
			return onidelapi.VM{}, fmt.Errorf("onidel: find the VM %q after create: %w", in.Name, err)
		}
	}

	vm, err := c.WaitForVMReady(ctx, id, in.TeamID)
	if err != nil {
		return onidelapi.VM{ID: id}, err
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
func findNewVM(vms []onidelapi.VM, existing map[string]bool, name string) string {
	var found onidelapi.VM
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

// UpdateVM applies one PATCH setting and waits for the VM to settle. teamID is the
// team the waits read the VM under; the setting carries its own.
func (c *Client) UpdateVM(ctx context.Context, id, teamID string, patch onidelapi.VMPatch) (onidelapi.VM, error) {
	if _, err := c.WaitForVMReady(ctx, id, teamID); err != nil {
		return onidelapi.VM{}, err
	}
	if err := requireSuccess(c.api.PatchVM(ctx, id, patch)); err != nil {
		return onidelapi.VM{}, err
	}
	return c.WaitForVMReady(ctx, id, teamID)
}

// RemoveVM destroys a VM (DELETE /vm/{id}) and waits until the API stops returning it.
// A VM that is already gone is not an error.
func (c *Client) RemoveVM(ctx context.Context, id, teamID string) error {
	err := requireSuccess(c.api.DeleteVM(ctx, id, &onidelapi.DeleteVMParams{TeamID: buildTeamID(teamID)}))
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
		return err == nil && vm.Status.IsGone(), err
	})
}

// VMStatusError is a VM in a status that never settles into active on its own, such
// as suspended or awaiting_payment.
type VMStatusError struct {
	ID     string
	Status onidelapi.VMStatus
}

func (e *VMStatusError) Error() string {
	return fmt.Sprintf("onidel: VM %s is %q, not active", e.ID, e.Status)
}

// WaitForVMReady polls until the VM is active with no action in flight.
func (c *Client) WaitForVMReady(ctx context.Context, id, teamID string) (onidelapi.VM, error) {
	var vm onidelapi.VM
	err := c.waitFor(ctx, c.VMWaitTimeout, func(ctx context.Context) (bool, error) {
		var err error
		vm, err = c.ReadVM(ctx, id, teamID)
		if err != nil {
			return false, err
		}
		if vm.Status == onidelapi.VMStatusActive {
			return !hasActiveAction(vm), nil
		}
		if vm.Status.IsSettling() {
			return false, nil
		}
		return false, &VMStatusError{ID: id, Status: vm.Status}
	})
	return vm, err
}
