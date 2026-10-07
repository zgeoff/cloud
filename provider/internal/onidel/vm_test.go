package onidel_test

import (
	"net/http"
	"testing"

	p "github.com/pulumi/pulumi-go-provider"
	"github.com/pulumi/pulumi-go-provider/infer"
	presource "github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestVMImportAdoptsTheLiveVMWithoutItsPassword(t *testing.T) {
	ctx := setupTest(t)
	// The shape of GET /vm/{id} for a live VM (values changed), password included.
	ctx.api.SetVM(map[string]any{
		"id": "0f289413-258f-4115-ac81-252000998fe0", "current_cpu_limit": nil, "cpu_limit_updated_at": nil,
		"cpu_limit_stale": true, "name": "edge", "vcpu": 8, "ram": 32768, "disk": 240, "location": "Melbourne",
		"password": "fixture-root-pw-do-not-leak", "bw_used": 0.73, "main_ipv4": "203.0.113.18",
		"main_ipv6": "2001:db8:4:17f::", "template": "Ubuntu 26.04 LTS x64",
		"created_at": "2026-10-02T05:48:53.632641Z", "renewed_at": "2026-10-02T05:48:53.632641Z",
		"due_date": "2026-11-02T05:48:53.467805Z", "recurring_amount": 94.68, "payment_currency": "aud",
		"billing_cycle": 1, "firewall_group_id": nil, "bgp_enabled": false, "status": "active", "active_action_id": nil,
	})

	read, err := ctx.server.Read(p.ReadRequest{ID: "0f289413-258f-4115-ac81-252000998fe0", Urn: onideltest.BuildURN("onidel:index:Vm", "edge")})

	require.NoError(t, err)
	assert.Equal(t, []any{
		"0f289413-258f-4115-ac81-252000998fe0",
		map[string]any{
			"name": "edge", "location": "Melbourne", "cpu": 8.0, "ram": 32768.0, "disk": 240.0, "os": 24.0, "ipv6": true,
		},
		map[string]any{
			"name": "edge", "location": "Melbourne", "cpu": 8.0, "ram": 32768.0, "disk": 240.0, "os": 24.0, "ipv6": true,
			"status": "active", "mainIpv4": "203.0.113.18", "mainIpv6": "2001:db8:4:17f::", "template": "Ubuntu 26.04 LTS x64",
			"bgpEnabled": false, "createdAt": "2026-10-02T05:48:53.632641Z",
		},
	}, []any{read.ID, onideltest.ToPlain(read.Inputs), onideltest.ToPlain(read.Properties)})
}

func TestVMImportLeavesOSUnsetForAnUnknownTemplate(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{
		"id": "v", "name": "web", "vcpu": 2, "ram": 4096, "disk": 40, "location": "Sydney", "main_ipv6": "",
		"template": "Custom ISO", "status": "active",
	})

	read, err := ctx.server.Read(p.ReadRequest{ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web")})

	require.NoError(t, err)
	assert.Equal(t, map[string]any{
		"name": "web", "location": "Sydney", "cpu": 2.0, "ram": 4096.0, "disk": 40.0, "ipv6": false,
	}, onideltest.ToPlain(read.Inputs))
}

func TestVMReadFailsWhenTheOSTemplatesCannotBeRead(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "location": "Sydney", "template": "Ubuntu 26.04 LTS x64", "status": "active"})
	ctx.api.RegisterResponse("GET /os_templates", http.StatusInternalServerError, "", 1)

	_, err := ctx.server.Read(p.ReadRequest{ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web")})

	assert.EqualError(t, err, "onidel: resolve the VM's OS template: onidel: GET /os_templates: HTTP 500")
}

func TestVMReadKeepsASnapshotSourceWithoutResolvingTheTemplate(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{
		"id": "v", "name": "web", "vcpu": 2, "ram": 4096, "disk": 40, "location": "Sydney",
		"template": "Ubuntu 26.04 LTS x64", "status": "active",
	})

	read, err := ctx.server.Read(p.ReadRequest{
		ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web"),
		Inputs: onideltest.BuildProps(map[string]any{
			"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "snapshotId": "s1",
		}),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{"name": "web", "location": "Sydney", "cpu": 2.0, "ram": 4096.0, "disk": 40.0, "snapshotId": "s1"},
		[]onideltest.Request{{Method: "GET", Path: "/teams"}, {Method: "GET", Path: "/vm/v", Query: "team_id=" + onideltest.TeamID}},
	}, []any{onideltest.ToPlain(read.Inputs), ctx.api.GetRequests()})
}

func TestVMReadReportsADeletedVMAsGone(t *testing.T) {
	ctx := setupTest(t)

	read, err := ctx.server.Read(p.ReadRequest{ID: "missing", Urn: onideltest.BuildURN("onidel:index:Vm", "web")})

	require.NoError(t, err)
	assert.Equal(t, "", read.ID)
}

func TestVMReadFailsWhenTheAPIFails(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /vm/{id}", http.StatusInternalServerError, "", 1)

	_, err := ctx.server.Read(p.ReadRequest{ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web")})

	assert.EqualError(t, err, "onidel: GET /vm/v: HTTP 500")
}

func TestVMReadKeepsTheProgramsFirewallUUIDWhileItsGroupHasAnInstance(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "location": "Sydney", "firewall_group_id": 1581, "status": "active"})
	ctx.api.SetFirewallGroup(map[string]any{"id": "f036620a-90df-4ba0-b7f0-54b4b5488bd2", "description": "edge", "instance_count": 1, "rule_count": 4})

	read, err := ctx.server.Read(p.ReadRequest{
		ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web"),
		Inputs: onideltest.BuildProps(map[string]any{
			"name": "web", "location": "Sydney", "cpu": 0, "ram": 0, "disk": 0, "snapshotId": "s1",
			"firewallGroupId": "f036620a-90df-4ba0-b7f0-54b4b5488bd2",
		}),
	})

	require.NoError(t, err)
	assert.Equal(t, map[string]any{
		"name": "web", "location": "Sydney", "cpu": 0.0, "ram": 0.0, "disk": 0.0, "snapshotId": "s1",
		"firewallGroupId": "f036620a-90df-4ba0-b7f0-54b4b5488bd2",
	}, onideltest.ToPlain(read.Inputs))
}

func TestVMReadReportsTheNumericFirewallIDWhenTheProgramsGroupIsNotInUse(t *testing.T) {
	rows := []struct {
		name  string
		group map[string]any
	}{
		{"it reports it when the program's group has no instance", map[string]any{"id": "f036620a-90df-4ba0-b7f0-54b4b5488bd2", "instance_count": 0}},
		{"it reports it when the program's group is gone", map[string]any{"id": "another-group", "instance_count": 1}},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "location": "Sydney", "firewall_group_id": 1581, "status": "active"})
			ctx.api.SetFirewallGroup(row.group)

			read, err := ctx.server.Read(p.ReadRequest{
				ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web"),
				Inputs: onideltest.BuildProps(map[string]any{
					"name": "web", "location": "Sydney", "cpu": 0, "ram": 0, "disk": 0, "snapshotId": "s1",
					"firewallGroupId": "f036620a-90df-4ba0-b7f0-54b4b5488bd2",
				}),
			})

			require.NoError(t, err)
			assert.Equal(t, map[string]any{
				"name": "web", "location": "Sydney", "cpu": 0.0, "ram": 0.0, "disk": 0.0, "snapshotId": "s1", "firewallGroupId": "1581",
			}, onideltest.ToPlain(read.Inputs))
		})
	}
}

func TestVMReadFailsWhenTheProgramsFirewallGroupCannotBeRead(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "location": "Sydney", "firewall_group_id": 1581, "status": "active"})
	ctx.api.RegisterResponse("GET /network/firewalls/{id}", http.StatusInternalServerError, "", 1)

	_, err := ctx.server.Read(p.ReadRequest{
		ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web"),
		Inputs: onideltest.BuildProps(map[string]any{
			"name": "web", "location": "Sydney", "cpu": 0, "ram": 0, "disk": 0, "snapshotId": "s1", "firewallGroupId": "g-uuid",
		}),
	})

	assert.EqualError(t, err, "onidel: GET /network/firewalls/g-uuid: HTTP 500")
}

func TestVMDiffAdoptsInputsTheAPICannotReportAfterAnImport(t *testing.T) {
	ctx := setupTest(t)

	diff, err := ctx.server.Diff(p.DiffRequest{
		ID: "0f289413-258f-4115-ac81-252000998fe0", Urn: onideltest.BuildURN("onidel:index:Vm", "edge"),
		State: onideltest.BuildProps(map[string]any{
			"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24, "ipv6": true,
			"status": "active", "mainIpv4": "203.0.113.18", "mainIpv6": "2001:db8:4:17f::", "template": "Ubuntu 26.04 LTS x64",
			"bgpEnabled": false, "createdAt": "2026-10-02T05:48:53.632641Z",
		}),
		OldInputs: onideltest.BuildProps(map[string]any{
			"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24, "ipv6": true,
		}),
		Inputs: onideltest.BuildProps(map[string]any{
			"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24,
			"paymentCycle": "monthly", "sshKeys": []any{"1423a98b-c6be-4dd8-b140-576e76c617d3"}, "ipv6": true,
		}),
	})

	require.NoError(t, err)
	assert.Equal(t, p.DiffResponse{DetailedDiff: map[string]p.PropertyDiff{}}, diff)
}

func TestVMDiffReportsEachChangedInput(t *testing.T) {
	rows := []struct {
		name   string
		inputs map[string]any
		want   p.DiffResponse
	}{
		{
			"it replaces for a new OS",
			map[string]any{"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 3, "paymentCycle": "monthly", "sshKeys": []any{"k1", "k2"}, "ipv6": true},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"os": {Kind: p.UpdateReplace, InputDiff: true}}},
		},
		{
			"it replaces for a new CPU count",
			map[string]any{"name": "edge", "location": "Melbourne", "cpu": 4, "ram": 32768, "disk": 240, "os": 24, "paymentCycle": "monthly", "sshKeys": []any{"k1", "k2"}, "ipv6": true},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"cpu": {Kind: p.UpdateReplace, InputDiff: true}}},
		},
		{
			"it replaces for a CPU count of zero",
			map[string]any{"name": "edge", "location": "Melbourne", "cpu": 0, "ram": 32768, "disk": 240, "os": 24, "paymentCycle": "monthly", "sshKeys": []any{"k1", "k2"}, "ipv6": true},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"cpu": {Kind: p.DeleteReplace, InputDiff: true}}},
		},
		{
			"it replaces for a new location",
			map[string]any{"name": "edge", "location": "Sydney", "cpu": 8, "ram": 32768, "disk": 240, "os": 24, "paymentCycle": "monthly", "sshKeys": []any{"k1", "k2"}, "ipv6": true},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"location": {Kind: p.UpdateReplace, InputDiff: true}}},
		},
		{
			"it replaces for more RAM",
			map[string]any{"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 65536, "disk": 240, "os": 24, "paymentCycle": "monthly", "sshKeys": []any{"k1", "k2"}, "ipv6": true},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"ram": {Kind: p.UpdateReplace, InputDiff: true}}},
		},
		{
			"it replaces for a bigger disk",
			map[string]any{"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 480, "os": 24, "paymentCycle": "monthly", "sshKeys": []any{"k1", "k2"}, "ipv6": true},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"disk": {Kind: p.UpdateReplace, InputDiff: true}}},
		},
		{
			"it compares the location without case",
			map[string]any{"name": "edge", "location": "melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24, "paymentCycle": "monthly", "sshKeys": []any{"k1", "k2"}, "ipv6": true},
			p.DiffResponse{DetailedDiff: map[string]p.PropertyDiff{}},
		},
		{
			"it replaces for a new payment cycle",
			map[string]any{"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24, "paymentCycle": "hourly", "sshKeys": []any{"k1", "k2"}, "ipv6": true},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"paymentCycle": {Kind: p.UpdateReplace, InputDiff: true}}},
		},
		{
			"it ignores the order of SSH keys",
			map[string]any{"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24, "paymentCycle": "monthly", "sshKeys": []any{"k2", "k1"}, "ipv6": true},
			p.DiffResponse{DetailedDiff: map[string]p.PropertyDiff{}},
		},
		{
			"it replaces for a new SSH key",
			map[string]any{"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24, "paymentCycle": "monthly", "sshKeys": []any{"k1", "k3"}, "ipv6": true},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"sshKeys": {Kind: p.UpdateReplace, InputDiff: true}}},
		},
		{
			"it renames in place",
			map[string]any{"name": "edge-2", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24, "paymentCycle": "monthly", "sshKeys": []any{"k1", "k2"}, "ipv6": true},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"name": {Kind: p.Update, InputDiff: true}}},
		},
		{
			"it toggles IPv6 in place",
			map[string]any{"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24, "paymentCycle": "monthly", "sshKeys": []any{"k1", "k2"}, "ipv6": false},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"ipv6": {Kind: p.Update, InputDiff: true}}},
		},
		{
			"it leaves IPv6 alone when the program unsets it",
			map[string]any{"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24, "paymentCycle": "monthly", "sshKeys": []any{"k1", "k2"}},
			p.DiffResponse{DetailedDiff: map[string]p.PropertyDiff{}},
		},
		{
			"it attaches a firewall group in place",
			map[string]any{"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24, "paymentCycle": "monthly", "sshKeys": []any{"k1", "k2"}, "ipv6": true, "firewallGroupId": "g1"},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"firewallGroupId": {Kind: p.Add, InputDiff: true}}},
		},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)

			diff, err := ctx.server.Diff(p.DiffRequest{
				ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "edge"),
				State: onideltest.BuildProps(map[string]any{
					"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24,
					"paymentCycle": "monthly", "sshKeys": []any{"k1", "k2"}, "ipv6": true,
					"status": "active", "mainIpv4": "203.0.113.18", "mainIpv6": "2001:db8:4:17f::", "template": "Ubuntu 26.04 LTS x64",
					"bgpEnabled": false, "createdAt": "2026-10-02T05:48:53.632641Z",
				}),
				Inputs: onideltest.BuildProps(row.inputs),
			})

			require.NoError(t, err)
			assert.Equal(t, row.want, diff)
		})
	}
}

func TestVMDiffReplacesForAnInputSetWhereStateHadNone(t *testing.T) {
	ctx := setupTest(t)

	diff, err := ctx.server.Diff(p.DiffRequest{
		ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "edge"),
		State: onideltest.BuildProps(map[string]any{
			"name": "edge", "location": "Melbourne", "cpu": 0, "ram": 32768, "disk": 240, "os": 24,
			"status": "active", "mainIpv4": "", "mainIpv6": "", "template": "", "bgpEnabled": false, "createdAt": "",
		}),
		Inputs: onideltest.BuildProps(map[string]any{"name": "edge", "location": "Melbourne", "cpu": 4, "ram": 32768, "disk": 240, "os": 24}),
	})

	require.NoError(t, err)
	assert.Equal(t, p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"cpu": {Kind: p.AddReplace, InputDiff: true}}}, diff)
}

func TestVMDiffDetachesAFirewallGroupTheProgramDrops(t *testing.T) {
	ctx := setupTest(t)

	diff, err := ctx.server.Diff(p.DiffRequest{
		ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "edge"),
		State: onideltest.BuildProps(map[string]any{
			"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24, "firewallGroupId": "g1",
			"status": "active", "mainIpv4": "", "mainIpv6": "", "template": "", "bgpEnabled": false, "createdAt": "",
		}),
		Inputs: onideltest.BuildProps(map[string]any{"name": "edge", "location": "Melbourne", "cpu": 8, "ram": 32768, "disk": 240, "os": 24}),
	})

	require.NoError(t, err)
	assert.Equal(t, p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"firewallGroupId": {Kind: p.Delete, InputDiff: true}}}, diff)
}

func TestVMCreateProvisionsTheVMAndWaitsUntilItIsActive(t *testing.T) {
	ctx := setupTest(t)

	created, err := ctx.server.Create(p.CreateRequest{
		Urn: onideltest.BuildURN("onidel:index:Vm", "web"),
		Properties: onideltest.BuildProps(map[string]any{
			"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24,
			"paymentCycle": "hourly", "sshKeys": []any{"key-1"}, "ipv6": false,
		}),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		"00000000-0000-4000-8000-000000000001",
		map[string]any{
			"name": "web", "location": "Sydney", "cpu": 2.0, "ram": 4096.0, "disk": 40.0, "os": 24.0,
			"paymentCycle": "hourly", "sshKeys": []any{"key-1"}, "ipv6": false,
			"status": "active", "mainIpv4": "203.0.113.10", "mainIpv6": "", "template": "Ubuntu 26.04 LTS x64",
			"bgpEnabled": false, "createdAt": "2026-10-02T05:48:53Z",
		},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "GET", Path: "/vm", Query: "team_id=" + onideltest.TeamID},
			{Method: "POST", Path: "/vm", Body: map[string]any{
				"team_id": onideltest.TeamID, "name": "web", "payment_cycle": "hourly", "location": "Sydney",
				"cpu": 2.0, "ram": 4096.0, "disk": 40.0, "os": 24.0, "ssh_keys": []any{"key-1"}, "ipv6": false,
			}},
			{Method: "GET", Path: "/vm", Query: "team_id=" + onideltest.TeamID},
			{Method: "GET", Path: "/vm/00000000-0000-4000-8000-000000000001", Query: "team_id=" + onideltest.TeamID},
			{Method: "GET", Path: "/vm/00000000-0000-4000-8000-000000000001", Query: "team_id=" + onideltest.TeamID},
		},
	}, []any{created.ID, onideltest.ToPlain(created.Properties), ctx.api.GetRequests()})
}

func TestVMCreateNeedsExactlyOneImageSource(t *testing.T) {
	rows := []struct {
		name   string
		inputs map[string]any
	}{
		{"it rejects a VM with no image source", map[string]any{"name": "x", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40}},
		{"it rejects a VM with two image sources", map[string]any{"name": "x", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24, "isoId": "i"}},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)

			_, err := ctx.server.Create(p.CreateRequest{Urn: onideltest.BuildURN("onidel:index:Vm", "x"), Properties: onideltest.BuildProps(row.inputs)})

			assert.EqualError(t, err, "onidel: a Vm needs exactly one of os, snapshotId or isoId")
			assert.Equal(t, []onideltest.Request(nil), ctx.api.GetRequests())
		})
	}
}

func TestVMCreatePreviewSendsNothing(t *testing.T) {
	ctx := setupTest(t)

	created, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:Vm", "web"),
		Properties: onideltest.BuildProps(map[string]any{"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24}),
		DryRun:     true,
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{
			"name": "web", "location": "Sydney", "cpu": 2.0, "ram": 4096.0, "disk": 40.0, "os": 24.0,
			"status":     presource.Computed{Element: presource.NewProperty("")},
			"mainIpv4":   presource.Computed{Element: presource.NewProperty("")},
			"mainIpv6":   presource.Computed{Element: presource.NewProperty("")},
			"template":   presource.Computed{Element: presource.NewProperty("")},
			"bgpEnabled": presource.Computed{Element: presource.NewProperty("")},
			"createdAt":  presource.Computed{Element: presource.NewProperty("")},
		},
		[]onideltest.Request(nil),
	}, []any{onideltest.ToPlain(created.Properties), ctx.api.GetRequests()})
}

func TestVMCreateKeepsAVMThatNeverBecomesReadyInState(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetAutoSettle(false)

	created, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:Vm", "web"),
		Properties: onideltest.BuildProps(map[string]any{"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24}),
	})

	var initFailed infer.ResourceInitFailedError
	require.ErrorAs(t, err, &initFailed)
	assert.Equal(t, []any{
		infer.ResourceInitFailedError{Reasons: []string{"context deadline exceeded"}},
		"00000000-0000-4000-8000-000000000001",
		map[string]map[string]any{"00000000-0000-4000-8000-000000000001": {
			"id": "00000000-0000-4000-8000-000000000001", "name": "web", "vcpu": 2.0, "ram": 4096.0, "disk": 40.0,
			"location": "Sydney", "password": "fixture-root-pw-do-not-leak", "main_ipv4": "203.0.113.10", "main_ipv6": "",
			"template": "Ubuntu 26.04 LTS x64", "firewall_group_id": nil, "created_at": "2026-10-02T05:48:53Z",
			"status": "building", "active_action_id": nil, "bgp_enabled": false,
		}},
	}, []any{initFailed, created.ID, ctx.api.GetVMs()})
	assert.Equal(t, []any{
		map[string]any{
			"name": "web", "location": "Sydney", "cpu": 2.0, "ram": 4096.0, "disk": 40.0, "os": 24.0,
			"status": "", "mainIpv4": "", "mainIpv6": "", "template": "", "bgpEnabled": false, "createdAt": "",
		},
		&p.InitializationFailed{Reasons: []string{"context deadline exceeded"}},
	}, []any{onideltest.ToPlain(created.Properties), created.PartialState})
}

func TestVMCreateFailsWithoutStateWhenTheAPIRefuses(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("POST /vm", http.StatusPaymentRequired, "", 1)

	created, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:Vm", "web"),
		Properties: onideltest.BuildProps(map[string]any{"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24}),
	})

	assert.EqualError(t, err, "onidel: POST /vm: HTTP 402")
	assert.Equal(t, "", created.ID)
}

func TestVMRefreshKeepsTheInputsTheAPIDoesNotReport(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{
		"id": "v", "name": "web", "vcpu": 2, "ram": 4096, "disk": 40, "location": "Sydney", "main_ipv4": "203.0.113.10",
		"main_ipv6": "", "template": "Ubuntu 26.04 LTS x64", "status": "active", "created_at": "2026-10-02T05:48:53Z",
	})

	read, err := ctx.server.Read(p.ReadRequest{
		ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web"),
		Inputs: onideltest.BuildProps(map[string]any{
			"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24,
			"paymentCycle": "hourly", "sshKeys": []any{"key-1"}, "instanceType": "t1", "ipv6": false,
		}),
	})

	require.NoError(t, err)
	assert.Equal(t, map[string]any{
		"name": "web", "location": "Sydney", "cpu": 2.0, "ram": 4096.0, "disk": 40.0, "os": 24.0,
		"paymentCycle": "hourly", "sshKeys": []any{"key-1"}, "instanceType": "t1", "ipv6": false,
	}, onideltest.ToPlain(read.Inputs))
}

func TestVMUpdateAppliesEachInPlaceChangeAsOnePatch(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{
		"id": "v", "name": "web", "vcpu": 2, "ram": 4096, "disk": 40, "location": "Sydney", "main_ipv4": "203.0.113.10",
		"main_ipv6": "", "template": "Ubuntu 26.04 LTS x64", "firewall_group_id": nil, "status": "active",
		"active_action_id": nil, "created_at": "2026-10-02T05:48:53Z", "password": "fixture-root-pw-do-not-leak",
	})

	updated, err := ctx.server.Update(p.UpdateRequest{
		ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web"),
		State: onideltest.BuildProps(map[string]any{
			"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24, "ipv6": false,
			"status": "active", "mainIpv4": "203.0.113.10", "mainIpv6": "", "template": "Ubuntu 26.04 LTS x64",
			"bgpEnabled": false, "createdAt": "2026-10-02T05:48:53Z",
		}),
		OldInputs: onideltest.BuildProps(map[string]any{"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24, "ipv6": false}),
		Inputs: onideltest.BuildProps(map[string]any{
			"name": "web-2", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24, "ipv6": true, "firewallGroupId": "fw-1",
		}),
	})

	require.NoError(t, err)
	get := onideltest.Request{Method: "GET", Path: "/vm/v", Query: "team_id=" + onideltest.TeamID}
	assert.Equal(t, []any{
		map[string]any{
			"name": "web-2", "location": "Sydney", "cpu": 2.0, "ram": 4096.0, "disk": 40.0, "os": 24.0, "ipv6": true,
			"firewallGroupId": "fw-1", "status": "active", "mainIpv4": "203.0.113.10", "mainIpv6": "2401:db8::1",
			"template": "Ubuntu 26.04 LTS x64", "bgpEnabled": false, "createdAt": "2026-10-02T05:48:53Z",
		},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			get,
			get, {Method: "PATCH", Path: "/vm/v", Body: map[string]any{"team_id": onideltest.TeamID, "name": "web-2"}}, get, get,
			get, {Method: "PATCH", Path: "/vm/v", Body: map[string]any{"team_id": onideltest.TeamID, "enable_ipv6": true}}, get, get,
			get, {Method: "PATCH", Path: "/vm/v", Body: map[string]any{"team_id": onideltest.TeamID, "firewall_group_id": "fw-1"}}, get, get,
		},
	}, []any{onideltest.ToPlain(updated.Properties), ctx.api.GetRequests()})
}

func TestVMUpdateDetachesTheFirewallGroupTheProgramDrops(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "location": "Sydney", "firewall_group_id": "fw-1", "status": "active", "active_action_id": nil})

	_, err := ctx.server.Update(p.UpdateRequest{
		ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web"),
		State: onideltest.BuildProps(map[string]any{
			"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24, "firewallGroupId": "fw-1",
			"status": "active", "mainIpv4": "", "mainIpv6": "", "template": "", "bgpEnabled": false, "createdAt": "",
		}),
		OldInputs: onideltest.BuildProps(map[string]any{"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24, "firewallGroupId": "fw-1"}),
		Inputs:    onideltest.BuildProps(map[string]any{"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24}),
	})

	require.NoError(t, err)
	get := onideltest.Request{Method: "GET", Path: "/vm/v", Query: "team_id=" + onideltest.TeamID}
	assert.Equal(t, []any{
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			get,
			get, {Method: "PATCH", Path: "/vm/v", Body: map[string]any{"team_id": onideltest.TeamID, "disable_firewall": true}}, get, get,
		},
		map[string]map[string]any{"v": {
			"id": "v", "name": "web", "location": "Sydney", "firewall_group_id": nil, "status": "active", "active_action_id": nil,
		}},
	}, []any{ctx.api.GetRequests(), ctx.api.GetVMs()})
}

func TestVMUpdatePreviewSendsNothing(t *testing.T) {
	ctx := setupTest(t)

	updated, err := ctx.server.Update(p.UpdateRequest{
		ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web"),
		State: onideltest.BuildProps(map[string]any{
			"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24,
			"status": "active", "mainIpv4": "203.0.113.10", "mainIpv6": "", "template": "Ubuntu 26.04 LTS x64",
			"bgpEnabled": false, "createdAt": "2026-10-02T05:48:53Z",
		}),
		OldInputs: onideltest.BuildProps(map[string]any{"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24}),
		Inputs:    onideltest.BuildProps(map[string]any{"name": "web-2", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24}),
		DryRun:    true,
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{
			"name": "web-2", "location": "Sydney", "cpu": 2.0, "ram": 4096.0, "disk": 40.0, "os": 24.0,
			"status":     presource.Computed{Element: presource.NewProperty("")},
			"mainIpv4":   presource.Computed{Element: presource.NewProperty("")},
			"mainIpv6":   presource.Computed{Element: presource.NewProperty("")},
			"template":   presource.Computed{Element: presource.NewProperty("")},
			"bgpEnabled": presource.Computed{Element: presource.NewProperty("")},
			"createdAt":  presource.Computed{Element: presource.NewProperty("")},
		},
		[]onideltest.Request(nil),
	}, []any{onideltest.ToPlain(updated.Properties), ctx.api.GetRequests()})
}

func TestVMUpdateFailsForAVMThatIsGone(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.server.Update(p.UpdateRequest{
		ID: "missing", Urn: onideltest.BuildURN("onidel:index:Vm", "web"),
		State: onideltest.BuildProps(map[string]any{
			"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24,
			"status": "active", "mainIpv4": "", "mainIpv6": "", "template": "", "bgpEnabled": false, "createdAt": "",
		}),
		OldInputs: onideltest.BuildProps(map[string]any{"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24}),
		Inputs:    onideltest.BuildProps(map[string]any{"name": "web-2", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24}),
	})

	assert.EqualError(t, err, "onidel: GET /vm/missing: HTTP 404")
}

func TestVMDeleteDestroysTheVMAndWaitsUntilItIsGone(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "status": "active"})

	err := ctx.server.Delete(p.DeleteRequest{
		ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web"),
		Properties: onideltest.BuildProps(map[string]any{
			"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24,
			"status": "active", "mainIpv4": "", "mainIpv6": "", "template": "", "bgpEnabled": false, "createdAt": "",
		}),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]map[string]any{},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "DELETE", Path: "/vm/v", Query: "team_id=" + onideltest.TeamID},
			{Method: "GET", Path: "/vm/v", Query: "team_id=" + onideltest.TeamID},
		},
	}, []any{ctx.api.GetVMs(), ctx.api.GetRequests()})
}

func TestVMDeleteAcceptsAVMThatIsAlreadyGone(t *testing.T) {
	ctx := setupTest(t)

	err := ctx.server.Delete(p.DeleteRequest{
		ID: "missing", Urn: onideltest.BuildURN("onidel:index:Vm", "web"),
		Properties: onideltest.BuildProps(map[string]any{
			"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24,
			"status": "active", "mainIpv4": "", "mainIpv6": "", "template": "", "bgpEnabled": false, "createdAt": "",
		}),
	})

	assert.NoError(t, err)
}

func TestVMReadAfterDeleteReportsTheVMAsGone(t *testing.T) {
	ctx := setupTest(t)
	urn := onideltest.BuildURN("onidel:index:Vm", "web")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24}),
	})
	require.NoError(t, err)
	require.NoError(t, ctx.server.Delete(p.DeleteRequest{ID: created.ID, Urn: urn, Properties: created.Properties}))

	read, err := ctx.server.Read(p.ReadRequest{ID: created.ID, Urn: urn, Properties: created.Properties})

	require.NoError(t, err)
	assert.Equal(t, "", read.ID)
}

func TestVMReadReportsTheFirewallGroupAsIsWithoutAPriorOne(t *testing.T) {
	rows := []struct {
		name     string
		reported any
		prior    map[string]any
		want     map[string]any
	}{
		{
			"it takes the numeric ID on import",
			1581,
			map[string]any{"name": "web", "location": "Sydney", "cpu": 0, "ram": 0, "disk": 0, "snapshotId": "s1"},
			map[string]any{"name": "web", "location": "Sydney", "cpu": 0.0, "ram": 0.0, "disk": 0.0, "snapshotId": "s1", "firewallGroupId": "1581"},
		},
		{
			"it keeps a prior ID the API reports unchanged",
			"g-uuid",
			map[string]any{"name": "web", "location": "Sydney", "cpu": 0, "ram": 0, "disk": 0, "snapshotId": "s1", "firewallGroupId": "g-uuid"},
			map[string]any{"name": "web", "location": "Sydney", "cpu": 0.0, "ram": 0.0, "disk": 0.0, "snapshotId": "s1", "firewallGroupId": "g-uuid"},
		},
		{
			"it takes a reported UUID that differs from the prior one",
			"g-other",
			map[string]any{"name": "web", "location": "Sydney", "cpu": 0, "ram": 0, "disk": 0, "snapshotId": "s1", "firewallGroupId": "g-uuid"},
			map[string]any{"name": "web", "location": "Sydney", "cpu": 0.0, "ram": 0.0, "disk": 0.0, "snapshotId": "s1", "firewallGroupId": "g-other"},
		},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "location": "Sydney", "firewall_group_id": row.reported, "status": "active"})

			read, err := ctx.server.Read(p.ReadRequest{
				ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web"), Inputs: onideltest.BuildProps(row.prior),
			})

			require.NoError(t, err)
			assert.Equal(t, []any{
				row.want,
				[]onideltest.Request{{Method: "GET", Path: "/teams"}, {Method: "GET", Path: "/vm/v", Query: "team_id=" + onideltest.TeamID}},
			}, []any{onideltest.ToPlain(read.Inputs), ctx.api.GetRequests()})
		})
	}
}

func TestVMUpdateStopsAtTheFirstPatchThatFails(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "location": "Sydney", "main_ipv6": "", "status": "active", "active_action_id": nil})
	ctx.api.RegisterResponse("PATCH /vm/{id}", http.StatusBadRequest, "", 1)

	_, err := ctx.server.Update(p.UpdateRequest{
		ID: "v", Urn: onideltest.BuildURN("onidel:index:Vm", "web"),
		State: onideltest.BuildProps(map[string]any{
			"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24, "ipv6": false,
			"status": "active", "mainIpv4": "", "mainIpv6": "", "template": "", "bgpEnabled": false, "createdAt": "",
		}),
		OldInputs: onideltest.BuildProps(map[string]any{"name": "web", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24, "ipv6": false}),
		Inputs:    onideltest.BuildProps(map[string]any{"name": "web-2", "location": "Sydney", "cpu": 2, "ram": 4096, "disk": 40, "os": 24, "ipv6": true}),
	})

	assert.EqualError(t, err, "onidel: PATCH /vm/v: HTTP 400")
	get := onideltest.Request{Method: "GET", Path: "/vm/v", Query: "team_id=" + onideltest.TeamID}
	assert.Equal(t, []onideltest.Request{
		{Method: "GET", Path: "/teams"},
		get,
		get, {Method: "PATCH", Path: "/vm/v", Body: map[string]any{"team_id": onideltest.TeamID, "name": "web-2"}},
	}, ctx.api.GetRequests())
}
