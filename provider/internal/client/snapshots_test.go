package client_test

import (
	"net/http"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onidelapi"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestCreateSnapshotStartsASnapshotOfTheVM(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "disk": 240, "status": "active"})

	started, err := ctx.client.CreateSnapshot(t.Context(), "v", onidelapi.NewSnapshot{Name: "pre-change", Desc: "2026-10-14T09:30Z"})

	require.NoError(t, err)
	assert.Equal(t, onidelapi.SnapshotStarted{SnapshotID: "00000000-0000-4000-8000-000000000001"}, started)
	assert.Equal(t, []onideltest.Request{{Method: "POST", Path: "/vm/v/snapshot", Body: map[string]any{
		"name": "pre-change", "desc": "2026-10-14T09:30Z",
	}}}, ctx.api.GetRequests())
}

func TestCreateSnapshotFailsForAMissingVM(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.client.CreateSnapshot(t.Context(), "missing", onidelapi.NewSnapshot{Name: "pre-change"})

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "POST", Path: "/vm/missing/snapshot", Status: 404}, apiErr)
	assert.Equal(t, []map[string]any{}, ctx.api.GetSnapshots())
}

func TestCreateSnapshotNeverRetries(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "status": "active"})
	ctx.api.RegisterResponse("POST /vm/{id}/snapshot", http.StatusServiceUnavailable, "", 1)

	_, err := ctx.client.CreateSnapshot(t.Context(), "v", onidelapi.NewSnapshot{Name: "pre-change"})

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "POST", Path: "/vm/v/snapshot", Status: 503}, apiErr)
	assert.Equal(t, []onideltest.Request{{Method: "POST", Path: "/vm/v/snapshot", Body: map[string]any{"name": "pre-change"}}},
		ctx.api.GetRequests())
}

func TestReadSnapshotsListsTheSnapshots(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "disk": 240, "status": "active"})
	_, err := ctx.client.CreateSnapshot(t.Context(), "v", onidelapi.NewSnapshot{Name: "pre-change"})
	require.NoError(t, err)

	snapshots, err := ctx.client.ReadSnapshots(t.Context())

	require.NoError(t, err)
	assert.Equal(t, []onidelapi.Snapshot{{
		ID: "00000000-0000-4000-8000-000000000001", CreatedAt: "2026-10-02T06:00:00Z", Name: "pre-change", Size: 240, Status: "pending",
	}}, snapshots)
}
