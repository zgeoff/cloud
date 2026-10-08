package client_test

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestReadVMDropsTheRootPassword(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{
		"id": "0f289413-258f-4115-ac81-252000998fe0", "name": "edge", "vcpu": 8, "ram": 32768,
		"disk": 240, "location": "Melbourne", "password": "fixture-root-pw-do-not-leak",
		"main_ipv4": "203.0.113.18", "main_ipv6": "2001:db8::", "template": "Ubuntu 26.04 LTS x64",
		"firewall_group_id": nil, "bgp_enabled": false, "status": "active", "active_action_id": nil,
		"created_at": "2026-10-02T05:48:53.632641Z",
	})

	vm, err := ctx.client.ReadVM(t.Context(), "0f289413-258f-4115-ac81-252000998fe0", "team-a")

	require.NoError(t, err)
	assert.Equal(t, client.VM{
		ID: "0f289413-258f-4115-ac81-252000998fe0", Name: "edge", VCPU: 8, RAM: 32768, Disk: 240,
		Location: "Melbourne", MainIPv4: "203.0.113.18", MainIPv6: "2001:db8::", Template: "Ubuntu 26.04 LTS x64",
		Status: "active", CreatedAt: "2026-10-02T05:48:53.632641Z", ActiveActionID: json.RawMessage("null"),
	}, vm)
}

func TestReadVMSendsTheTeam(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "status": "active"})

	_, err := ctx.client.ReadVM(t.Context(), "v", "team-a")

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/vm/v", Query: "team_id=team-a"}}, ctx.api.GetRequests())
}

func TestReadVMDecodesANumericFirewallGroupID(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "firewall_group_id": 1581})

	vm, err := ctx.client.ReadVM(t.Context(), "v", "")

	require.NoError(t, err)
	assert.Equal(t, client.VM{ID: "v", FirewallGroupID: "1581"}, vm)
}

func TestReadVMsListsTheTeamsVMsInOrder(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "b", "name": "web", "status": "active"})
	ctx.api.SetVM(map[string]any{"id": "a", "name": "db", "status": "building"})

	vms, err := ctx.client.ReadVMs(t.Context(), "team-a")

	require.NoError(t, err)
	assert.Equal(t, []client.VM{{ID: "b", Name: "web", Status: "active"}, {ID: "a", Name: "db", Status: "building"}}, vms)
}

func TestCreateVMFindsTheNewVMByListingAfterABodylessCreate(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "old", "name": "web", "status": "active", "created_at": "2026-01-01T00:00:00Z"})

	vm, err := ctx.client.CreateVM(t.Context(), client.VMInput{
		TeamID: "team-a", Name: "web", Location: "Sydney", CPU: 2, RAM: 4096, Disk: 40, OS: new(24),
	})

	require.NoError(t, err)
	assert.Equal(t, client.VM{
		ID: "00000000-0000-4000-8000-000000000001", Name: "web", VCPU: 2, RAM: 4096, Disk: 40, Location: "Sydney",
		MainIPv4: "203.0.113.10", Template: "Ubuntu 26.04 LTS x64", Status: "active",
		CreatedAt: "2026-10-02T05:48:53Z", ActiveActionID: json.RawMessage("null"),
	}, vm)
}

func TestCreateVMSendsTheInputAsTheCreateBody(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.client.CreateVM(t.Context(), client.VMInput{
		TeamID: "team-a", Name: "web", PaymentCycle: "hourly", Location: "Sydney", CPU: 2, RAM: 4096, Disk: 40,
		OS: new(24), SSHKeys: []string{"key-1"}, FirewallGroupID: "g1", IPv6: true,
	})

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{
		{Method: "GET", Path: "/vm", Query: "team_id=team-a"},
		{Method: "POST", Path: "/vm", Body: map[string]any{
			"team_id": "team-a", "name": "web", "payment_cycle": "hourly", "location": "Sydney", "cpu": 2.0,
			"ram": 4096.0, "disk": 40.0, "os": 24.0, "ssh_keys": []any{"key-1"}, "firewall_group_id": "g1", "ipv6": true,
		}},
		{Method: "GET", Path: "/vm", Query: "team_id=team-a"},
		{Method: "GET", Path: "/vm/00000000-0000-4000-8000-000000000001", Query: "team_id=team-a"},
		{Method: "GET", Path: "/vm/00000000-0000-4000-8000-000000000001", Query: "team_id=team-a"},
	}, ctx.api.GetRequests())
}

func TestCreateVMPicksTheNewestNewVMWithTheRequestedName(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterHandler("POST /vm", func(w http.ResponseWriter, _ *http.Request) {
		ctx.api.SetVM(map[string]any{"id": "older", "name": "web", "status": "active", "created_at": "2026-10-01T00:00:00Z"})
		ctx.api.SetVM(map[string]any{"id": "newer", "name": "web", "status": "active", "created_at": "2026-10-02T00:00:00Z"})
		ctx.api.SetVM(map[string]any{"id": "other", "name": "db", "status": "active", "created_at": "2026-10-03T00:00:00Z"})
		w.WriteHeader(http.StatusCreated)
	})

	vm, err := ctx.client.CreateVM(t.Context(), client.VMInput{Name: "web", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20, OS: new(24)})

	require.NoError(t, err)
	assert.Equal(t, client.VM{ID: "newer", Name: "web", Status: "active", CreatedAt: "2026-10-02T00:00:00Z"}, vm)
}

func TestCreateVMTakesTheIDFromACreateBodyThatCarriesOne(t *testing.T) {
	rows := []struct {
		name string
		body string
	}{
		{"it reads a top-level id", `{"id":"0f289413-258f-4115-ac81-252000998fe0","password":"fixture-root-pw-do-not-leak"}`},
		{"it reads a vm_id", `{"vm_id":"0f289413-258f-4115-ac81-252000998fe0"}`},
		{"it reads a nested vm id", `{"vm":{"id":"0f289413-258f-4115-ac81-252000998fe0"}}`},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.RegisterHandler("POST /vm", func(w http.ResponseWriter, _ *http.Request) {
				ctx.api.SetVM(map[string]any{"id": "0f289413-258f-4115-ac81-252000998fe0", "name": "web", "status": "building"})
				w.WriteHeader(http.StatusCreated)
				_, _ = w.Write([]byte(row.body))
			})

			vm, err := ctx.client.CreateVM(t.Context(), client.VMInput{Name: "web", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20, OS: new(24)})

			require.NoError(t, err)
			assert.Equal(t, client.VM{ID: "0f289413-258f-4115-ac81-252000998fe0", Name: "web", Status: "active", ActiveActionID: json.RawMessage("null")}, vm)
			assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/vm"}, {Method: "POST", Path: "/vm", Body: map[string]any{
				"name": "web", "location": "Sydney", "cpu": 1.0, "ram": 1024.0, "disk": 20.0, "os": 24.0, "ipv6": false,
			}}, {Method: "GET", Path: "/vm/0f289413-258f-4115-ac81-252000998fe0"},
				{Method: "GET", Path: "/vm/0f289413-258f-4115-ac81-252000998fe0"}}, ctx.api.GetRequests())
		})
	}
}

func TestCreateVMFallsBackToListingWhenTheCreateBodyCarriesNoID(t *testing.T) {
	rows := []struct {
		name string
		body string
	}{
		{"it lists after a body that is not JSON", `created`},
		{"it lists after an empty JSON object", `{}`},
		{"it lists after a JSON body without an ID field", `{"name":"web","status":"building"}`},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.RegisterHandler("POST /vm", func(w http.ResponseWriter, _ *http.Request) {
				ctx.api.SetVM(map[string]any{"id": "listed", "name": "web", "status": "active"})
				w.WriteHeader(http.StatusCreated)
				_, _ = w.Write([]byte(row.body))
			})

			vm, err := ctx.client.CreateVM(t.Context(), client.VMInput{Name: "web", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20, OS: new(24)})

			require.NoError(t, err)
			assert.Equal(t, client.VM{ID: "listed", Name: "web", Status: "active"}, vm)
			assert.Equal(t, []onideltest.Request{
				{Method: "GET", Path: "/vm"},
				{Method: "POST", Path: "/vm", Body: map[string]any{
					"name": "web", "location": "Sydney", "cpu": 1.0, "ram": 1024.0, "disk": 20.0, "os": 24.0, "ipv6": false,
				}},
				{Method: "GET", Path: "/vm"},
				{Method: "GET", Path: "/vm/listed"},
			}, ctx.api.GetRequests())
		})
	}
}

func TestCreateVMFailsWhenTheFirstListingFails(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /vm", http.StatusInternalServerError, "", 1)

	vm, err := ctx.client.CreateVM(t.Context(), client.VMInput{Name: "web", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20, OS: new(24)})

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "GET", Path: "/vm", Status: 500}, apiErr)
	assert.Equal(t, client.VM{}, vm)
	assert.Equal(t, map[string]map[string]any{}, ctx.api.GetVMs())
}

func TestCreateVMFailsWhenTheAPIRefusesTheCreate(t *testing.T) {
	ctx := setupTest(t)

	vm, err := ctx.client.CreateVM(t.Context(), client.VMInput{Name: "web", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20})

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "POST", Path: "/vm", Status: 400}, apiErr)
	assert.Equal(t, client.VM{}, vm)
}

func TestCreateVMFailsWhenTheNewVMNeverAppears(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("POST /vm", http.StatusCreated, "", 1)

	vm, err := ctx.client.CreateVM(t.Context(), client.VMInput{Name: "web", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20, OS: new(24)})

	assert.EqualError(t, err, `onidel: find the VM "web" after create: context deadline exceeded`)
	assert.Equal(t, client.VM{}, vm)
	assert.Equal(t, slices.Repeat([]time.Duration{10 * time.Second}, 180), ctx.sleep.GetDurations())
}

func TestCreateVMFailsWhenTheListingFailsAfterTheCreate(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterHandler("POST /vm", func(w http.ResponseWriter, _ *http.Request) {
		ctx.api.RegisterResponse("GET /vm", http.StatusInternalServerError, "", 1)
		w.WriteHeader(http.StatusCreated)
	})

	vm, err := ctx.client.CreateVM(t.Context(), client.VMInput{Name: "web", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20, OS: new(24)})

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "GET", Path: "/vm", Status: 500}, apiErr)
	assert.EqualError(t, err, `onidel: find the VM "web" after create: onidel: GET /vm: HTTP 500`)
	assert.Equal(t, client.VM{}, vm)
}

func TestCreateVMReturnsTheIDOfAVMThatNeverBecomesReady(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetAutoSettle(false)

	vm, err := ctx.client.CreateVM(t.Context(), client.VMInput{Name: "web", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20, OS: new(24)})

	require.ErrorIs(t, err, context.DeadlineExceeded)
	assert.Equal(t, client.VM{ID: "00000000-0000-4000-8000-000000000001"}, vm)
	assert.Equal(t, slices.Repeat([]time.Duration{10 * time.Second}, 180), ctx.sleep.GetDurations())
}

func TestWaitForVMReadyWaitsForAnActiveVMWithNoActionInFlight(t *testing.T) {
	rows := []struct {
		name   string
		status string
		action any
	}{
		{"it waits while the VM builds", "building", nil},
		{"it waits while the VM restores", "restoring", nil},
		{"it waits while the VM migrates", "migrating", nil},
		{"it waits while the VM takes a snapshot", "taking_snaphot", nil},
		{"it waits while an action runs on an active VM", "active", 42},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetVM(map[string]any{"id": "v", "status": row.status, "active_action_id": row.action})

			vm, err := ctx.client.WaitForVMReady(t.Context(), "v", "")

			require.NoError(t, err)
			assert.Equal(t, client.VM{ID: "v", Status: "active", ActiveActionID: json.RawMessage("null")}, vm)
			assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/vm/v"}, {Method: "GET", Path: "/vm/v"}}, ctx.api.GetRequests())
		})
	}
}

func TestWaitForVMReadyFailsOnAStatusThatNeverSettles(t *testing.T) {
	rows := []struct {
		name   string
		status string
	}{
		{"it fails on awaiting_payment", "awaiting_payment"},
		{"it fails on suspended", "suspended"},
		{"it fails on terminating", "terminating"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetVM(map[string]any{"id": "v", "status": row.status})

			_, err := ctx.client.WaitForVMReady(t.Context(), "v", "")

			var statusErr *client.VMStatusError
			require.ErrorAs(t, err, &statusErr)
			assert.Equal(t, &client.VMStatusError{ID: "v", Status: row.status}, statusErr)
			assert.EqualError(t, err, `onidel: VM v is "`+row.status+`", not active`)
		})
	}
}

func TestWaitForVMReadyFailsWhenTheReadFails(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.client.WaitForVMReady(t.Context(), "missing", "")

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "GET", Path: "/vm/missing", Status: 404}, apiErr)
}

func TestUpdateVMAppliesOneSettingAndWaitsForItToSettle(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "status": "active", "active_action_id": nil})

	vm, err := ctx.client.UpdateVM(t.Context(), "v", client.VMPatch{TeamID: "team-a", Name: "web-2"})

	require.NoError(t, err)
	assert.Equal(t, client.VM{ID: "v", Name: "web-2", Status: "active", ActiveActionID: json.RawMessage("null")}, vm)
	assert.Equal(t, []onideltest.Request{
		{Method: "GET", Path: "/vm/v", Query: "team_id=team-a"},
		{Method: "PATCH", Path: "/vm/v", Body: map[string]any{"team_id": "team-a", "name": "web-2"}},
		{Method: "GET", Path: "/vm/v", Query: "team_id=team-a"},
		{Method: "GET", Path: "/vm/v", Query: "team_id=team-a"},
	}, ctx.api.GetRequests())
}

func TestUpdateVMFailsForAMissingVM(t *testing.T) {
	ctx := setupTest(t)

	vm, err := ctx.client.UpdateVM(t.Context(), "missing", client.VMPatch{Name: "web-2"})

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "GET", Path: "/vm/missing", Status: 404}, apiErr)
	assert.Equal(t, client.VM{}, vm)
}

func TestUpdateVMFailsWhenTheAPIRefusesThePatch(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "status": "active", "active_action_id": nil})

	vm, err := ctx.client.UpdateVM(t.Context(), "v", client.VMPatch{})

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "PATCH", Path: "/vm/v", Status: 400}, apiErr)
	assert.Equal(t, client.VM{}, vm)
}

func TestRemoveVMWaitsUntilTheVMIsGone(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "status": "active"})

	err := ctx.client.RemoveVM(t.Context(), "v", "team-a")

	require.NoError(t, err)
	assert.Equal(t, map[string]map[string]any{}, ctx.api.GetVMs())
	assert.Equal(t, []onideltest.Request{
		{Method: "DELETE", Path: "/vm/v", Query: "team_id=team-a"},
		{Method: "GET", Path: "/vm/v", Query: "team_id=team-a"},
	}, ctx.api.GetRequests())
}

func TestRemoveVMAcceptsAVMThatIsAlreadyGone(t *testing.T) {
	ctx := setupTest(t)

	err := ctx.client.RemoveVM(t.Context(), "missing", "")

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{{Method: "DELETE", Path: "/vm/missing"}}, ctx.api.GetRequests())
}

func TestRemoveVMAcceptsAVMStillListedAsDestroyed(t *testing.T) {
	rows := []struct {
		name   string
		status string
	}{
		{"it accepts terminated", "terminated"},
		{"it accepts deleted", "deleted"},
		{"it accepts destroyed", "destroyed"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			// Undocumented: a destroyed VM may stay listed under a terminal status.
			ctx.api.SetVM(map[string]any{"id": "v", "status": row.status})
			ctx.api.RegisterResponse("DELETE /vm/{id}", http.StatusNoContent, "", 1)

			err := ctx.client.RemoveVM(t.Context(), "v", "")

			require.NoError(t, err)
			assert.Equal(t, []onideltest.Request{{Method: "DELETE", Path: "/vm/v"}, {Method: "GET", Path: "/vm/v"}}, ctx.api.GetRequests())
		})
	}
}

func TestRemoveVMFailsWhenTheAPIRefusesTheDelete(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("DELETE /vm/{id}", http.StatusBadRequest, "", 1)

	err := ctx.client.RemoveVM(t.Context(), "v", "")

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "DELETE", Path: "/vm/v", Status: 400}, apiErr)
}

func TestRemoveVMFailsWhenTheReadAfterTheDeleteFails(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "status": "active"})
	ctx.api.RegisterResponse("GET /vm/{id}", http.StatusInternalServerError, "", 1)

	err := ctx.client.RemoveVM(t.Context(), "v", "")

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "GET", Path: "/vm/v", Status: 500}, apiErr)
}
func TestReadVMReportsAMissingVMAsNotFound(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.client.ReadVM(t.Context(), "x", "team")

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "GET", Path: "/vm/x", Status: 404}, apiErr)
	assert.True(t, client.IsNotFound(err))
}

func TestWaitForVMReadyWaitsThroughTheAlternativeSnapshotSpelling(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "status": "active", "active_action_id": nil})
	// The spec spells it taking_snaphot; the client also accepts taking_snapshot,
	// which the stub does not model, so one canned read reports it.
	ctx.api.RegisterResponse("GET /vm/{id}", http.StatusOK, `{"id":"v","status":"taking_snapshot"}`, 1)

	vm, err := ctx.client.WaitForVMReady(t.Context(), "v", "")

	require.NoError(t, err)
	assert.Equal(t, client.VM{ID: "v", Status: "active", ActiveActionID: json.RawMessage("null")}, vm)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/vm/v"}, {Method: "GET", Path: "/vm/v"}}, ctx.api.GetRequests())
}

func TestWaitForVMReadyStopsWhenTheContextEnds(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "status": "building"})
	ctx.api.SetAutoSettle(false)
	callCtx, cancel := context.WithCancel(t.Context())
	t.Cleanup(cancel)
	ctx.client.Sleep = onideltest.BuildStubCancelingSleep(cancel).Sleep

	_, err := ctx.client.WaitForVMReady(callCtx, "v", "")

	assert.Equal(t, context.Canceled, err)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/vm/v"}}, ctx.api.GetRequests())
}
