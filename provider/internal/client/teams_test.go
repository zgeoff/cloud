package client_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
)

func TestReadTeamsListsTheCallersTeams(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(
		map[string]any{"id": "team-a", "name": "a", "role": "Team Owner"},
		map[string]any{"id": "team-b", "name": "b", "role": "Team Member"},
	)

	teams, err := ctx.client.ReadTeams(t.Context())

	require.NoError(t, err)
	assert.Equal(t, []client.Team{{ID: "team-a", Name: "a", Role: "Team Owner"}, {ID: "team-b", Name: "b", Role: "Team Member"}}, teams)
}
