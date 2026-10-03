package onidel

import (
	"testing"

	p "github.com/pulumi/pulumi-go-provider"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const vmToken = "onidel:index:Vm"

// liveShapedVM mirrors GET /vm/{id} for the real geoffcloud VM (values changed),
// including the plain-text password the API returns.
func liveShapedVM(id string) map[string]any {
	return map[string]any{
		"id": id, "current_cpu_limit": nil, "cpu_limit_updated_at": nil, "cpu_limit_stale": true,
		"name": "geoffcloud", "vcpu": 8, "ram": 32768, "disk": 240, "location": "Melbourne",
		"password": fakeRootPassword, "bw_used": 0.73, "main_ipv4": "203.0.113.18",
		"main_ipv6": "2001:db8:4:17f::", "template": "Ubuntu 26.04 LTS x64",
		"created_at": "2026-10-02T05:48:53.632641Z", "renewed_at": "2026-10-02T05:48:53.632641Z",
		"due_date": "2026-11-02T05:48:53.467805Z", "recurring_amount": 94.68, "payment_currency": "aud",
		"billing_cycle": 1, "firewall_group_id": nil, "bgp_enabled": false, "status": "active",
		"active_action_id": nil,
	}
}

func vmProgramInputs() map[string]any {
	return map[string]any{
		"name": "geoffcloud", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24,
		"paymentCycle": "monthly", "sshKeys": []any{"1423a98b-c6be-4dd8-b140-576e76c617d3"}, "ipv6": true,
	}
}

func TestVMPasswordNeverReachesState(t *testing.T) {
	server, api := setupTestServer(t)
	const id = "0f289413-258f-4115-ac81-252000998fe0"
	api.vms[id] = liveShapedVM(id)

	// Import path: Read with only an ID.
	read, err := server.Read(p.ReadRequest{ID: id, Urn: buildURN(vmToken, "geoffcloud")})
	require.NoError(t, err)
	require.Equal(t, id, read.ID)
	assert.NotContains(t, encodeProps(t, read.Properties), fakeRootPassword)
	assert.NotContains(t, encodeProps(t, read.Inputs), fakeRootPassword)
	assert.NotContains(t, encodeProps(t, read.Properties), "password")

	// Create path: the fake returns the password on every GET.
	created, err := server.Create(p.CreateRequest{
		Urn:        buildURN(vmToken, "new"),
		Properties: buildProps(map[string]any{"name": "new", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24}),
	})
	require.NoError(t, err)
	assert.NotContains(t, encodeProps(t, created.Properties), fakeRootPassword)
	assert.NotContains(t, encodeProps(t, created.Properties), "password")
}

func TestVMImportAdoptsWithoutReplace(t *testing.T) {
	server, api := setupTestServer(t)
	const id = "0f289413-258f-4115-ac81-252000998fe0"
	api.vms[id] = liveShapedVM(id)

	read, err := server.Read(p.ReadRequest{ID: id, Urn: buildURN(vmToken, "geoffcloud")})
	require.NoError(t, err)
	inputs := toPlain(read.Inputs)
	assert.Equal(t, "geoffcloud", inputs["name"])
	assert.Equal(t, "Melbourne", inputs["location"])
	assert.EqualValues(t, 8, inputs["cpu"])
	assert.EqualValues(t, 32768, inputs["ram"])
	assert.EqualValues(t, 240, inputs["disk"])
	assert.EqualValues(t, 24, inputs["os"], "os resolves from the template name")
	assert.Equal(t, true, inputs["ipv6"])
	assert.NotContains(t, inputs, "firewallGroupId")

	// The program sets fields the API cannot report: they are adopted, not a replace.
	diff, err := server.Diff(p.DiffRequest{
		ID: id, Urn: buildURN(vmToken, "geoffcloud"),
		State: read.Properties, OldInputs: read.Inputs, Inputs: buildProps(vmProgramInputs()),
	})
	require.NoError(t, err)
	assert.False(t, diff.HasChanges, "unexpected diff: %v", diff.DetailedDiff)

	// A real change to a create-only field still replaces.
	changed := vmProgramInputs()
	changed["os"] = 3
	changed["cpu"] = 4
	diff, err = server.Diff(p.DiffRequest{
		ID: id, Urn: buildURN(vmToken, "geoffcloud"),
		State: read.Properties, OldInputs: read.Inputs, Inputs: buildProps(changed),
	})
	require.NoError(t, err)
	assert.True(t, diff.HasChanges)
	assert.Equal(t, p.UpdateReplace, diff.DetailedDiff["os"].Kind)
	assert.Equal(t, p.UpdateReplace, diff.DetailedDiff["cpu"].Kind)
}

func TestVMReadKeepsFirewallUUIDOverNumericID(t *testing.T) {
	server, api := setupTestServer(t)
	const id = "0f289413-258f-4115-ac81-252000998fe0"
	const groupID = "f036620a-90df-4ba0-b7f0-54b4b5488bd2"
	vm := liveShapedVM(id)
	vm["firewall_group_id"] = 1581
	api.vms[id] = vm
	api.firewalls[groupID] = map[string]any{
		"id": groupID, "description": "geoff.cloud edge", "instance_count": 1, "rule_count": 4,
	}
	program := vmProgramInputs()
	program["firewallGroupId"] = groupID
	urn := buildURN(vmToken, "geoffcloud")

	read, err := server.Read(p.ReadRequest{ID: id, Urn: urn, Inputs: buildProps(program)})
	require.NoError(t, err)
	assert.Equal(t, groupID, toPlain(read.Inputs)["firewallGroupId"])
	diff, err := server.Diff(p.DiffRequest{
		ID: id, Urn: urn, State: read.Properties, OldInputs: read.Inputs, Inputs: buildProps(program),
	})
	require.NoError(t, err)
	assert.False(t, diff.HasChanges, "unexpected diff: %v", diff.DetailedDiff)

	// With no instance on the program's group, the VM is on some other group.
	api.firewalls[groupID]["instance_count"] = 0
	read, err = server.Read(p.ReadRequest{ID: id, Urn: urn, Inputs: buildProps(program)})
	require.NoError(t, err)
	assert.Equal(t, "1581", toPlain(read.Inputs)["firewallGroupId"])
}

func TestVMLifecycle(t *testing.T) {
	server, api := setupTestServer(t)
	urn := buildURN(vmToken, "web")
	inputs := map[string]any{
		"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24,
		"paymentCycle": "hourly", "sshKeys": []any{"key-1"}, "ipv6": false,
	}

	created, err := server.Create(p.CreateRequest{Urn: urn, Properties: buildProps(inputs)})
	require.NoError(t, err)
	require.NotEmpty(t, created.ID, "the ID is found by listing after a bodyless 201")
	out := toPlain(created.Properties)
	assert.Equal(t, "active", out["status"])
	assert.Equal(t, "203.0.113.10", out["mainIpv4"])
	posts := api.collectRequests("POST")
	require.Len(t, posts, 1)
	assert.Equal(t, "/vm", posts[0].Path)
	assert.EqualValues(t, 24, posts[0].Body["os"])
	assert.EqualValues(t, 2, posts[0].Body["cpu"])
	assert.Equal(t, "hourly", posts[0].Body["payment_cycle"])
	assert.Equal(t, []any{"key-1"}, posts[0].Body["ssh_keys"])

	read, err := server.Read(p.ReadRequest{ID: created.ID, Urn: urn, Properties: created.Properties, Inputs: buildProps(inputs)})
	require.NoError(t, err)
	assert.Equal(t, "hourly", toPlain(read.Inputs)["paymentCycle"], "unreported inputs survive a refresh")

	// Rename, enable IPv6 and attach a firewall: three single-setting PATCHes.
	next := map[string]any{}
	for k, v := range inputs {
		next[k] = v
	}
	next["name"] = "web-2"
	next["ipv6"] = true
	next["firewallGroupId"] = "fw-1"
	diff, err := server.Diff(p.DiffRequest{ID: created.ID, Urn: urn, State: read.Properties, OldInputs: read.Inputs, Inputs: buildProps(next)})
	require.NoError(t, err)
	assert.Equal(t, p.Update, diff.DetailedDiff["name"].Kind)
	assert.Equal(t, p.Update, diff.DetailedDiff["ipv6"].Kind)
	assert.Equal(t, p.Add, diff.DetailedDiff["firewallGroupId"].Kind)
	assert.Len(t, diff.DetailedDiff, 3)

	updated, err := server.Update(p.UpdateRequest{
		ID: created.ID, Urn: urn, State: read.Properties, OldInputs: read.Inputs, Inputs: buildProps(next),
	})
	require.NoError(t, err)
	patches := api.collectRequests("PATCH")
	require.Len(t, patches, 3)
	assert.Equal(t, "web-2", patches[0].Body["name"])
	assert.Equal(t, true, patches[1].Body["enable_ipv6"])
	assert.Equal(t, "fw-1", patches[2].Body["firewall_group_id"])
	out = toPlain(updated.Properties)
	assert.Equal(t, "web-2", out["name"])
	assert.Equal(t, "fw-1", out["firewallGroupId"])
	assert.NotContains(t, encodeProps(t, updated.Properties), fakeRootPassword)

	// Removing the firewall detaches it.
	detached := map[string]any{}
	for k, v := range next {
		detached[k] = v
	}
	delete(detached, "firewallGroupId")
	_, err = server.Update(p.UpdateRequest{
		ID: created.ID, Urn: urn, State: updated.Properties, OldInputs: buildProps(next), Inputs: buildProps(detached),
	})
	require.NoError(t, err)
	patches = api.collectRequests("PATCH")
	require.Len(t, patches, 4)
	assert.Equal(t, true, patches[3].Body["disable_firewall"])

	require.NoError(t, server.Delete(p.DeleteRequest{ID: created.ID, Urn: urn, Properties: updated.Properties}))
	assert.Empty(t, api.vms)

	gone, err := server.Read(p.ReadRequest{ID: created.ID, Urn: urn, Properties: updated.Properties})
	require.NoError(t, err)
	assert.Empty(t, gone.ID, "a 404 reads as deleted")
}

func TestVMCreateNeedsOneImageSource(t *testing.T) {
	server, _ := setupTestServer(t)
	_, err := server.Create(p.CreateRequest{
		Urn:        buildURN(vmToken, "x"),
		Properties: buildProps(map[string]any{"name": "x", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40}),
	})
	require.ErrorContains(t, err, "exactly one of os, snapshotId or isoId")
}

func TestVMDiffReplaceFields(t *testing.T) {
	server, api := setupTestServer(t)
	const id = "0f289413-258f-4115-ac81-252000998fe0"
	api.vms[id] = liveShapedVM(id)
	read, err := server.Read(p.ReadRequest{ID: id, Urn: buildURN(vmToken, "geoffcloud")})
	require.NoError(t, err)

	for field, value := range map[string]any{"location": "Sydney", "ram": 65536, "disk": 480} {
		in := vmProgramInputs()
		in[field] = value
		diff, err := server.Diff(p.DiffRequest{
			ID: id, Urn: buildURN(vmToken, "geoffcloud"), State: read.Properties, OldInputs: read.Inputs, Inputs: buildProps(in),
		})
		require.NoError(t, err)
		assert.Equal(t, p.UpdateReplace, diff.DetailedDiff[field].Kind, field)
	}

	// Location compares case-insensitively.
	in := vmProgramInputs()
	in["location"] = "melbourne"
	diff, err := server.Diff(p.DiffRequest{
		ID: id, Urn: buildURN(vmToken, "geoffcloud"), State: read.Properties, OldInputs: read.Inputs, Inputs: buildProps(in),
	})
	require.NoError(t, err)
	assert.False(t, diff.HasChanges)
}
