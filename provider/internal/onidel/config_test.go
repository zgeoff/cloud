package onidel_test

import (
	"net/http"
	"testing"

	p "github.com/pulumi/pulumi-go-provider"
	"github.com/pulumi/pulumi-go-provider/infer"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/onidel"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestConfigDiffUpdatesTheProviderInPlace(t *testing.T) {
	rows := []struct {
		name   string
		state  *onidel.Config
		inputs *onidel.Config
		want   infer.DiffResponse
	}{
		{
			"it updates a rotated API key in place",
			&onidel.Config{APIKey: "old"}, &onidel.Config{APIKey: "new"},
			infer.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"apiKey": {Kind: p.Update, InputDiff: true}}},
		},
		{
			"it updates a changed team in place",
			&onidel.Config{TeamID: "team-a"}, &onidel.Config{TeamID: "team-b"},
			infer.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"teamId": {Kind: p.Update, InputDiff: true}}},
		},
		{
			"it updates a changed endpoint in place",
			&onidel.Config{Endpoint: "https://a.example"}, &onidel.Config{Endpoint: "https://b.example"},
			infer.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"endpoint": {Kind: p.Update, InputDiff: true}}},
		},
		{
			"it reports no change for an equal config",
			&onidel.Config{APIKey: "same", TeamID: "team-a"}, &onidel.Config{APIKey: "same", TeamID: "team-a"},
			infer.DiffResponse{DetailedDiff: map[string]p.PropertyDiff{}},
		},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			resp, err := (&onidel.Config{}).Diff(t.Context(), infer.DiffRequest[*onidel.Config, *onidel.Config]{State: row.state, Inputs: row.inputs})

			require.NoError(t, err)
			assert.Equal(t, row.want, resp)
		})
	}
}

func TestConfigureFailsWithoutAnAPIKey(t *testing.T) {
	t.Setenv(onidel.APIKeyEnv, "")

	err := (&onidel.Config{}).Configure(t.Context())

	require.ErrorIs(t, err, onidel.ErrMissingAPIKey)
	assert.EqualError(t, err, "onidel: set the apiKey config or ONIDEL_API_KEY")
}

func TestConfigureFallsBackToTheEnvironmentForTheAPIKey(t *testing.T) {
	t.Setenv(onidel.APIKeyEnv, "from-env")
	cfg := &onidel.Config{}

	err := cfg.Configure(t.Context())

	require.NoError(t, err)
	assert.Equal(t, "from-env", cfg.APIKey)
}

func TestConfigurePrefersTheConfiguredAPIKeyOverTheEnvironment(t *testing.T) {
	t.Setenv(onidel.APIKeyEnv, "from-env")
	cfg := &onidel.Config{APIKey: "from-config"}

	err := cfg.Configure(t.Context())

	require.NoError(t, err)
	assert.Equal(t, "from-config", cfg.APIKey)
}

func TestConfigUsesTheConfiguredTeamWithoutListingTeams(t *testing.T) {
	ctx := setupTest(t)
	require.NoError(t, ctx.server.Configure(p.ConfigureRequest{Args: onideltest.BuildProps(map[string]any{
		"apiKey": onideltest.APIKey, "endpoint": ctx.api.URL, "teamId": "team-a",
	})}))

	_, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:FirewallGroup", "fw"),
		Properties: onideltest.BuildProps(map[string]any{"description": "edge"}),
	})

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{
		{Method: "POST", Path: "/network/firewalls", Body: map[string]any{"team_id": "team-a", "description": "edge"}},
	}, ctx.api.GetRequests())
}

func TestConfigListsTeamsOnlyOnce(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
	_, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:FirewallGroup", "a"),
		Properties: onideltest.BuildProps(map[string]any{"description": "a"}),
	})
	require.NoError(t, err)

	_, err = ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:FirewallGroup", "b"),
		Properties: onideltest.BuildProps(map[string]any{"description": "b"}),
	})

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{
		{Method: "GET", Path: "/teams"},
		{Method: "POST", Path: "/network/firewalls", Body: map[string]any{"team_id": "team-a", "description": "a"}},
		{Method: "POST", Path: "/network/firewalls", Body: map[string]any{"team_id": "team-a", "description": "b"}},
	}, ctx.api.GetRequests())
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

			_, err := ctx.server.Create(p.CreateRequest{
				Urn:        onideltest.BuildURN("onidel:index:SshKey", "me"),
				Properties: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}),
			})

			assert.EqualError(t, err, row.want)
			assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/teams"}}, ctx.api.GetRequests())
		})
	}
}

func TestConfigSendsNoTeamOnAReadWhenTheTeamLookupFails(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /teams", http.StatusInternalServerError, "", 1)

	read, err := ctx.server.Read(p.ReadRequest{ID: "k", Urn: onideltest.BuildURN("onidel:index:SshKey", "me")})

	require.NoError(t, err)
	assert.Equal(t, []any{"", []onideltest.Request{{Method: "GET", Path: "/teams"}, {Method: "GET", Path: "/ssh_keys/k"}}},
		[]any{read.ID, ctx.api.GetRequests()})
}

func TestConfigSendsNoTeamOnADeleteWhenTheTeamLookupFails(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /teams", http.StatusInternalServerError, "", 1)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "instance_count": 0})

	err := ctx.server.Delete(p.DeleteRequest{
		ID: "g1", Urn: onideltest.BuildURN("onidel:index:FirewallGroup", "fw"),
		Properties: onideltest.BuildProps(map[string]any{
			"description": "edge", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-02T00:00:00Z",
			"instanceCount": 0, "ruleCount": 0,
		}),
	})

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/teams"}, {Method: "DELETE", Path: "/network/firewalls/g1"}},
		ctx.api.GetRequests())
}
