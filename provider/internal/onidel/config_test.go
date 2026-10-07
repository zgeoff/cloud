package onidel

import (
	"net/http"
	"testing"

	p "github.com/pulumi/pulumi-go-provider"
	"github.com/pulumi/pulumi-go-provider/infer"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestConfigDiffUpdatesTheProviderInPlace(t *testing.T) {
	rows := []struct {
		name   string
		state  *Config
		inputs *Config
		want   infer.DiffResponse
	}{
		{
			"it updates a rotated API key in place",
			&Config{APIKey: "old"}, &Config{APIKey: "new"},
			infer.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"apiKey": {Kind: p.Update, InputDiff: true}}},
		},
		{
			"it updates a changed team in place",
			&Config{TeamID: "team-a"}, &Config{TeamID: "team-b"},
			infer.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"teamId": {Kind: p.Update, InputDiff: true}}},
		},
		{
			"it updates a changed endpoint in place",
			&Config{Endpoint: "https://a.example"}, &Config{Endpoint: "https://b.example"},
			infer.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"endpoint": {Kind: p.Update, InputDiff: true}}},
		},
		{
			"it reports no change for an equal config",
			&Config{APIKey: "same", TeamID: "team-a"}, &Config{APIKey: "same", TeamID: "team-a"},
			infer.DiffResponse{DetailedDiff: map[string]p.PropertyDiff{}},
		},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			resp, err := (&Config{}).Diff(t.Context(), infer.DiffRequest[*Config, *Config]{State: row.state, Inputs: row.inputs})

			require.NoError(t, err)
			assert.Equal(t, row.want, resp)
		})
	}
}

func TestConfigureFailsWithoutAnAPIKey(t *testing.T) {
	t.Setenv(APIKeyEnv, "")

	err := (&Config{}).Configure(t.Context())

	assert.EqualError(t, err, "onidel: set the apiKey config or ONIDEL_API_KEY")
}

func TestConfigureFallsBackToTheEnvironmentForTheAPIKey(t *testing.T) {
	t.Setenv(APIKeyEnv, "from-env")
	cfg := &Config{}

	err := cfg.Configure(t.Context())

	require.NoError(t, err)
	assert.Equal(t, "from-env", cfg.APIKey)
}

func TestConfigurePrefersTheConfiguredAPIKeyOverTheEnvironment(t *testing.T) {
	t.Setenv(APIKeyEnv, "from-env")
	cfg := &Config{APIKey: "from-config"}

	err := cfg.Configure(t.Context())

	require.NoError(t, err)
	assert.Equal(t, "from-config", cfg.APIKey)
}

func TestConfigUsesTheConfiguredTeamWithoutListingTeams(t *testing.T) {
	ctx := setupTest(t)
	cfg := &Config{APIKey: onideltest.APIKey, TeamID: "team-a", Endpoint: ctx.api.URL}
	require.NoError(t, cfg.Configure(t.Context()))

	teamID, err := cfg.resolveTeamID(t.Context())

	require.NoError(t, err)
	assert.Equal(t, []any{"team-a", []onideltest.Request(nil)}, []any{teamID, ctx.api.GetRequests()})
}

func TestConfigUsesTheAPIKeysOnlyTeam(t *testing.T) {
	ctx := setupTest(t)
	cfg := &Config{APIKey: onideltest.APIKey, Endpoint: ctx.api.URL}
	require.NoError(t, cfg.Configure(t.Context()))

	teamID, err := cfg.resolveTeamID(t.Context())

	require.NoError(t, err)
	assert.Equal(t, onideltest.TeamID, teamID)
}

func TestConfigListsTeamsOnlyOnce(t *testing.T) {
	ctx := setupTest(t)
	cfg := &Config{APIKey: onideltest.APIKey, Endpoint: ctx.api.URL}
	require.NoError(t, cfg.Configure(t.Context()))

	_, _ = cfg.resolveTeamID(t.Context())
	teamID, err := cfg.resolveTeamID(t.Context())

	require.NoError(t, err)
	assert.Equal(t, []any{onideltest.TeamID, []onideltest.Request{{Method: "GET", Path: "/teams"}}},
		[]any{teamID, ctx.api.GetRequests()})
}

func TestConfigFailsWhenTheAPIKeyDoesNotSeeExactlyOneTeam(t *testing.T) {
	rows := []struct {
		name  string
		teams []map[string]any
		want  string
	}{
		{"it fails for no team", nil, "onidel: the API key can see 0 teams; set the teamId config"},
		{"it fails for two teams", []map[string]any{
			{"id": "team-a", "name": "a", "role": "Team Owner"},
			{"id": "team-b", "name": "b", "role": "Team Member"},
		}, "onidel: the API key can see 2 teams; set the teamId config"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetTeams(row.teams...)
			cfg := &Config{APIKey: onideltest.APIKey, Endpoint: ctx.api.URL}
			require.NoError(t, cfg.Configure(t.Context()))

			teamID, err := cfg.resolveTeamID(t.Context())

			assert.EqualError(t, err, row.want)
			assert.Equal(t, "", teamID)
		})
	}
}

func TestConfigFailsWhenTheTeamLookupFails(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterHandler("GET /teams", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	})
	cfg := &Config{APIKey: onideltest.APIKey, Endpoint: ctx.api.URL}
	require.NoError(t, cfg.Configure(t.Context()))

	_, err := cfg.resolveTeamID(t.Context())

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "GET", Path: "/teams", Status: 500}, apiErr)
}
