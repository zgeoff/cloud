package client_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestCreateSSHKeyReturnsTheStoredKey(t *testing.T) {
	ctx := setupTest(t)

	key, err := ctx.client.CreateSSHKey(t.Context(), client.SSHKeyInput{TeamID: "team-a", Name: "me", PublicKey: "ssh-ed25519 AAAA me@host"})

	require.NoError(t, err)
	assert.Equal(t, client.SSHKey{
		ID: "00000000-0000-4000-8000-000000000001", Created: "2026-10-02T05:35:28Z", Name: "me", PublicKey: "ssh-ed25519 AAAA me@host",
	}, key)
}

func TestCreateSSHKeyFailsWithoutATeam(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.client.CreateSSHKey(t.Context(), client.SSHKeyInput{Name: "me", PublicKey: "ssh-ed25519 AAAA me@host"})

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "POST", Path: "/ssh_keys", Status: 400}, apiErr)
}

func TestReadSSHKeyReadsOneKeyInTheTeam(t *testing.T) {
	ctx := setupTest(t)
	_, err := ctx.client.CreateSSHKey(t.Context(), client.SSHKeyInput{TeamID: "team-a", Name: "me", PublicKey: "k"})
	require.NoError(t, err)

	key, err := ctx.client.ReadSSHKey(t.Context(), "00000000-0000-4000-8000-000000000001", "team-a")

	require.NoError(t, err)
	assert.Equal(t, client.SSHKey{ID: "00000000-0000-4000-8000-000000000001", Created: "2026-10-02T05:35:28Z", Name: "me", PublicKey: "k"}, key)
	assert.Equal(t, []onideltest.Request{
		{Method: "POST", Path: "/ssh_keys", Body: map[string]any{"team_id": "team-a", "name": "me", "ssh_key": "k"}},
		{Method: "GET", Path: "/ssh_keys/00000000-0000-4000-8000-000000000001", Query: "team_id=team-a"},
	}, ctx.api.GetRequests())
}

func TestUpdateSSHKeySendsTheWholeKey(t *testing.T) {
	ctx := setupTest(t)
	_, err := ctx.client.CreateSSHKey(t.Context(), client.SSHKeyInput{TeamID: "team-a", Name: "me", PublicKey: "k1"})
	require.NoError(t, err)

	err = ctx.client.UpdateSSHKey(t.Context(), "00000000-0000-4000-8000-000000000001", client.SSHKeyInput{TeamID: "team-a", Name: "me-2", PublicKey: "k2"})

	require.NoError(t, err)
	assert.Equal(t, map[string]map[string]any{"00000000-0000-4000-8000-000000000001": {
		"id": "00000000-0000-4000-8000-000000000001", "created": "2026-10-02T05:35:28Z", "name": "me-2", "ssh_key": "k2",
	}}, ctx.api.GetSSHKeys())
}

func TestRemoveSSHKeyRemovesTheKeyInTheTeam(t *testing.T) {
	ctx := setupTest(t)
	_, err := ctx.client.CreateSSHKey(t.Context(), client.SSHKeyInput{TeamID: "team-a", Name: "me", PublicKey: "k"})
	require.NoError(t, err)

	err = ctx.client.RemoveSSHKey(t.Context(), "00000000-0000-4000-8000-000000000001", "team-a")

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]map[string]any{},
		[]onideltest.Request{
			{Method: "POST", Path: "/ssh_keys", Body: map[string]any{"team_id": "team-a", "name": "me", "ssh_key": "k"}},
			{Method: "DELETE", Path: "/ssh_keys/00000000-0000-4000-8000-000000000001", Query: "team_id=team-a"},
		},
	}, []any{ctx.api.GetSSHKeys(), ctx.api.GetRequests()})
}
