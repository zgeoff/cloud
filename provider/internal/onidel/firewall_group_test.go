package onidel_test

import (
	"net/http"
	"testing"

	p "github.com/pulumi/pulumi-go-provider"
	presource "github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestFirewallGroupCreateAddsTheGroupToTheResolvedTeam(t *testing.T) {
	ctx := setupTest(t)

	created, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:FirewallGroup", "fw"),
		Properties: onideltest.BuildProps(map[string]any{"description": "cloud"}),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		"00000000-0000-4000-8000-000000000001",
		map[string]any{
			"description": "cloud", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-02T00:00:00Z",
			"instanceCount": 0.0, "ruleCount": 0.0,
		},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "POST", Path: "/network/firewalls", Body: map[string]any{"team_id": onideltest.TeamID, "description": "cloud"}},
		},
	}, []any{created.ID, onideltest.ToPlain(created.Properties), ctx.api.GetRequests()})
}

func TestFirewallGroupCreatePreviewSendsNothing(t *testing.T) {
	ctx := setupTest(t)

	created, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:FirewallGroup", "fw"),
		Properties: onideltest.BuildProps(map[string]any{"description": "cloud"}),
		DryRun:     true,
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{
			"description": "cloud", "created": presource.Computed{Element: presource.NewProperty("")},
			"updated":       presource.Computed{Element: presource.NewProperty("")},
			"instanceCount": presource.Computed{Element: presource.NewProperty("")},
			"ruleCount":     presource.Computed{Element: presource.NewProperty("")},
		},
		[]onideltest.Request(nil),
	}, []any{onideltest.ToPlain(created.Properties), ctx.api.GetRequests()})
}

func TestFirewallGroupCreateFailsWithTheAPIsErrorWhenNoTeamResolves(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams()

	_, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:FirewallGroup", "fw"),
		Properties: onideltest.BuildProps(map[string]any{"description": "cloud"}),
	})

	assert.EqualError(t, err, "onidel: POST /network/firewalls: HTTP 401: UNAUTHORIZED")
}

func TestFirewallGroupImportReadsTheGroupByID(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{
		"id": "g1", "description": "cloud", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-03T00:00:00Z",
		"instance_count": 1, "rule_count": 4,
	})

	read, err := ctx.server.Read(p.ReadRequest{ID: "g1", Urn: onideltest.BuildURN("onidel:index:FirewallGroup", "fw")})

	require.NoError(t, err)
	assert.Equal(t, []any{
		"g1",
		map[string]any{"description": "cloud"},
		map[string]any{
			"description": "cloud", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-03T00:00:00Z",
			"instanceCount": 1.0, "ruleCount": 4.0,
		},
	}, []any{read.ID, onideltest.ToPlain(read.Inputs), onideltest.ToPlain(read.Properties)})
}

func TestFirewallGroupReadReportsADeletedGroupAsGone(t *testing.T) {
	ctx := setupTest(t)

	read, err := ctx.server.Read(p.ReadRequest{ID: "missing", Urn: onideltest.BuildURN("onidel:index:FirewallGroup", "fw")})

	require.NoError(t, err)
	assert.Equal(t, "", read.ID)
}

func TestFirewallGroupReadFailsWhenTheAPIFails(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /network/firewalls/{id}", http.StatusInternalServerError, "", 1)

	_, err := ctx.server.Read(p.ReadRequest{ID: "g1", Urn: onideltest.BuildURN("onidel:index:FirewallGroup", "fw")})

	assert.EqualError(t, err, "onidel: GET /network/firewalls/g1: HTTP 500")
}

func TestFirewallGroupDiffUpdatesTheDescriptionInPlace(t *testing.T) {
	ctx := setupTest(t)

	diff, err := ctx.server.Diff(p.DiffRequest{
		ID: "g1", Urn: onideltest.BuildURN("onidel:index:FirewallGroup", "fw"),
		State: onideltest.BuildProps(map[string]any{
			"description": "cloud", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-02T00:00:00Z",
			"instanceCount": 0, "ruleCount": 0,
		}),
		OldInputs: onideltest.BuildProps(map[string]any{"description": "cloud"}),
		Inputs:    onideltest.BuildProps(map[string]any{"description": "cloud host"}),
	})

	require.NoError(t, err)
	assert.Equal(t, p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"description": {Kind: p.Update}}}, diff)
}

func TestFirewallGroupUpdateChangesTheDescriptionAndRereadsTheGroup(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{
		"id": "g1", "description": "cloud", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-02T00:00:00Z",
		"instance_count": 0, "rule_count": 0,
	})

	updated, err := ctx.server.Update(p.UpdateRequest{
		ID: "g1", Urn: onideltest.BuildURN("onidel:index:FirewallGroup", "fw"),
		State: onideltest.BuildProps(map[string]any{
			"description": "cloud", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-02T00:00:00Z",
			"instanceCount": 0, "ruleCount": 0,
		}),
		OldInputs: onideltest.BuildProps(map[string]any{"description": "cloud"}),
		Inputs:    onideltest.BuildProps(map[string]any{"description": "cloud host"}),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{
			"description": "cloud host", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-03T00:00:00Z",
			"instanceCount": 0.0, "ruleCount": 0.0,
		},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "PUT", Path: "/network/firewalls/g1", Body: map[string]any{"team_id": onideltest.TeamID, "description": "cloud host"}},
			{Method: "GET", Path: "/network/firewalls/g1"},
		},
	}, []any{onideltest.ToPlain(updated.Properties), ctx.api.GetRequests()})
}

func TestFirewallGroupUpdatePreviewSendsNothing(t *testing.T) {
	ctx := setupTest(t)

	updated, err := ctx.server.Update(p.UpdateRequest{
		ID: "g1", Urn: onideltest.BuildURN("onidel:index:FirewallGroup", "fw"),
		State: onideltest.BuildProps(map[string]any{
			"description": "cloud", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-02T00:00:00Z",
			"instanceCount": 0, "ruleCount": 0,
		}),
		OldInputs: onideltest.BuildProps(map[string]any{"description": "cloud"}),
		Inputs:    onideltest.BuildProps(map[string]any{"description": "cloud host"}),
		DryRun:    true,
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{
			"description": "cloud host", "created": presource.Computed{Element: presource.NewProperty("")},
			"updated":       presource.Computed{Element: presource.NewProperty("")},
			"instanceCount": presource.Computed{Element: presource.NewProperty("")},
			"ruleCount":     presource.Computed{Element: presource.NewProperty("")},
		},
		[]onideltest.Request(nil),
	}, []any{onideltest.ToPlain(updated.Properties), ctx.api.GetRequests()})
}

func TestFirewallGroupUpdateFailsWhenTheGroupIsGone(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.server.Update(p.UpdateRequest{
		ID: "missing", Urn: onideltest.BuildURN("onidel:index:FirewallGroup", "fw"),
		State: onideltest.BuildProps(map[string]any{
			"description": "cloud", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-02T00:00:00Z",
			"instanceCount": 0, "ruleCount": 0,
		}),
		OldInputs: onideltest.BuildProps(map[string]any{"description": "cloud"}),
		Inputs:    onideltest.BuildProps(map[string]any{"description": "cloud host"}),
	})

	assert.EqualError(t, err, "onidel: PUT /network/firewalls/missing: HTTP 404")
}

func TestFirewallGroupUpdateFailsWhenTheRereadFails(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "description": "cloud"})
	ctx.api.RegisterResponse("GET /network/firewalls/{id}", http.StatusInternalServerError, "", 1)

	_, err := ctx.server.Update(p.UpdateRequest{
		ID: "g1", Urn: onideltest.BuildURN("onidel:index:FirewallGroup", "fw"),
		State: onideltest.BuildProps(map[string]any{
			"description": "cloud", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-02T00:00:00Z",
			"instanceCount": 0, "ruleCount": 0,
		}),
		OldInputs: onideltest.BuildProps(map[string]any{"description": "cloud"}),
		Inputs:    onideltest.BuildProps(map[string]any{"description": "cloud host"}),
	})

	assert.EqualError(t, err, "onidel: GET /network/firewalls/g1: HTTP 500")
}

func TestFirewallGroupDeleteRemovesTheGroupFromTheTeam(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "description": "cloud", "instance_count": 0})

	err := ctx.server.Delete(p.DeleteRequest{
		ID: "g1", Urn: onideltest.BuildURN("onidel:index:FirewallGroup", "fw"),
		Properties: onideltest.BuildProps(map[string]any{
			"description": "cloud", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-02T00:00:00Z",
			"instanceCount": 0, "ruleCount": 0,
		}),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]map[string]any{},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "DELETE", Path: "/network/firewalls/g1", Query: "team_id=" + onideltest.TeamID},
		},
	}, []any{ctx.api.GetFirewallGroups(), ctx.api.GetRequests()})
}

func TestFirewallGroupDeleteAcceptsAGroupThatIsAlreadyGone(t *testing.T) {
	ctx := setupTest(t)

	err := ctx.server.Delete(p.DeleteRequest{
		ID: "missing", Urn: onideltest.BuildURN("onidel:index:FirewallGroup", "fw"),
		Properties: onideltest.BuildProps(map[string]any{
			"description": "cloud", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-02T00:00:00Z",
			"instanceCount": 0, "ruleCount": 0,
		}),
	})

	assert.NoError(t, err)
}

func TestFirewallGroupDeleteFailsWhileVMsAreAttached(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "description": "cloud", "instance_count": 1})

	err := ctx.server.Delete(p.DeleteRequest{
		ID: "g1", Urn: onideltest.BuildURN("onidel:index:FirewallGroup", "fw"),
		Properties: onideltest.BuildProps(map[string]any{
			"description": "cloud", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-02T00:00:00Z",
			"instanceCount": 1, "ruleCount": 0,
		}),
	})

	assert.EqualError(t, err, "onidel: DELETE /network/firewalls/g1: HTTP 400")
}
