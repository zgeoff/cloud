package client_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/clienttest"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestCreateSSHKeyReturnsTheStoredKey(t *testing.T) {
	ctx := setupTest(t)

	key, err := ctx.client.CreateSSHKey(t.Context(), clienttest.BuildMockSSHKeyInput(func(in *client.SSHKeyInput) {
		in.TeamID, in.Name, in.PublicKey = "team-a", "me", "ssh-ed25519 AAAA me@host"
	}))

	require.NoError(t, err)
	assert.Equal(t, client.SSHKey{
		ID: "00000000-0000-4000-8000-000000000001", Created: "2026-10-02T05:35:28Z", Name: "me", PublicKey: "ssh-ed25519 AAAA me@host",
	}, key)
}

func TestCreateSSHKeyFailsWithoutATeam(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.client.CreateSSHKey(t.Context(), clienttest.BuildMockSSHKeyInput(func(in *client.SSHKeyInput) {
		in.TeamID = ""
	}))

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "POST", Path: "/ssh_keys", Status: 400}, apiErr)
}

func TestReadSSHKeyReadsOneKeyInTheTeam(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetSSHKey(map[string]any{"id": "k1", "created": "2026-10-02T05:35:28Z", "name": "me", "ssh_key": "k"})

	key, err := ctx.client.ReadSSHKey(t.Context(), "k1", "team-a")

	require.NoError(t, err)
	assert.Equal(t, client.SSHKey{ID: "k1", Created: "2026-10-02T05:35:28Z", Name: "me", PublicKey: "k"}, key)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/ssh_keys/k1", Query: "team_id=team-a"}}, ctx.api.GetRequests())
}

func TestUpdateSSHKeySendsTheWholeKey(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetSSHKey(map[string]any{"id": "k1", "created": "2026-10-02T05:35:28Z", "name": "me", "ssh_key": "k"})

	err := ctx.client.UpdateSSHKey(t.Context(), "k1", clienttest.BuildMockSSHKeyInput(func(in *client.SSHKeyInput) {
		in.TeamID, in.Name, in.PublicKey = "team-a", "me-2", "k2"
	}))

	require.NoError(t, err)
	assert.Equal(t, map[string]map[string]any{"k1": {"id": "k1", "created": "2026-10-02T05:35:28Z", "name": "me-2", "ssh_key": "k2"}}, ctx.api.GetSSHKeys())
	assert.Equal(t, []onideltest.Request{{Method: "PATCH", Path: "/ssh_keys/k1", Body: map[string]any{
		"team_id": "team-a", "name": "me-2", "ssh_key": "k2",
	}}}, ctx.api.GetRequests())
}

func TestRemoveSSHKeyRemovesTheKeyInTheTeam(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetSSHKey(map[string]any{"id": "k1", "created": "2026-10-02T05:35:28Z", "name": "me", "ssh_key": "k"})

	err := ctx.client.RemoveSSHKey(t.Context(), "k1", "team-a")

	require.NoError(t, err)
	assert.Equal(t, map[string]map[string]any{}, ctx.api.GetSSHKeys())
	assert.Equal(t, []onideltest.Request{{Method: "DELETE", Path: "/ssh_keys/k1", Query: "team_id=team-a"}}, ctx.api.GetRequests())
}
