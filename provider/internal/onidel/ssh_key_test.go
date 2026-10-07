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

func TestSSHKeyCreateAddsTheKeyToTheResolvedTeam(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})

	created, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:SshKey", "me"),
		Properties: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAAC3Nza me@host\n"}),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		"00000000-0000-4000-8000-000000000001",
		map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAAC3Nza me@host\n", "created": "2026-10-02T05:35:28Z"},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "POST", Path: "/ssh_keys", Body: map[string]any{
				"team_id": "team-a", "name": "me", "ssh_key": "ssh-ed25519 AAAAC3Nza me@host\n",
			}},
		},
	}, []any{created.ID, onideltest.ToPlain(created.Properties), ctx.api.GetRequests()})
}

func TestSSHKeyCreatePreviewSendsNothing(t *testing.T) {
	ctx := setupTest(t)

	created, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:SshKey", "me"),
		Properties: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}),
		DryRun:     true,
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host", "created": presource.Computed{Element: presource.NewProperty("")}},
		[]onideltest.Request(nil),
	}, []any{onideltest.ToPlain(created.Properties), ctx.api.GetRequests()})
}

func TestSSHKeyCreateFailsWhenTheTeamLookupFails(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /teams", http.StatusInternalServerError, "", 1)

	_, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:SshKey", "me"),
		Properties: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}),
	})

	assert.EqualError(t, err, "onidel: GET /teams: HTTP 500")
}

func TestSSHKeyReadKeepsTheProgramsSpellingOfAnEquivalentPublicKey(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
	urn := onideltest.BuildURN("onidel:index:SshKey", "me")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}),
	})
	require.NoError(t, err)

	read, err := ctx.server.Read(p.ReadRequest{
		ID: created.ID, Urn: urn, Properties: created.Properties,
		Inputs: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host\n"}),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		created.ID,
		map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host\n"},
		map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host\n", "created": "2026-10-02T05:35:28Z"},
	}, []any{read.ID, onideltest.ToPlain(read.Inputs), onideltest.ToPlain(read.Properties)})
}

func TestSSHKeyReadReportsAPublicKeyChangedOutsideTheProgram(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
	urn := onideltest.BuildURN("onidel:index:SshKey", "me")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 BBBB me@host"}),
	})
	require.NoError(t, err)

	read, err := ctx.server.Read(p.ReadRequest{
		ID: created.ID, Urn: urn, Properties: created.Properties,
		Inputs: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}),
	})

	require.NoError(t, err)
	assert.Equal(t, map[string]any{"name": "me", "publicKey": "ssh-ed25519 BBBB me@host"}, onideltest.ToPlain(read.Inputs))
}

func TestSSHKeyImportReadsTheKeyByIDInTheTeam(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
	urn := onideltest.BuildURN("onidel:index:SshKey", "me")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}),
	})
	require.NoError(t, err)

	read, err := ctx.server.Read(p.ReadRequest{ID: created.ID, Urn: urn})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "POST", Path: "/ssh_keys", Body: map[string]any{"team_id": "team-a", "name": "me", "ssh_key": "ssh-ed25519 AAAA me@host"}},
			{Method: "GET", Path: "/ssh_keys/" + created.ID, Query: "team_id=team-a"},
		},
	}, []any{onideltest.ToPlain(read.Inputs), ctx.api.GetRequests()})
}

func TestSSHKeyReadReportsADeletedKeyAsGone(t *testing.T) {
	ctx := setupTest(t)

	read, err := ctx.server.Read(p.ReadRequest{ID: "missing", Urn: onideltest.BuildURN("onidel:index:SshKey", "me")})

	require.NoError(t, err)
	assert.Equal(t, "", read.ID)
}

func TestSSHKeyDiffUpdatesTheNameAndPublicKeyInPlace(t *testing.T) {
	ctx := setupTest(t)
	old := map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}

	diff, err := ctx.server.Diff(p.DiffRequest{
		ID: "k", Urn: onideltest.BuildURN("onidel:index:SshKey", "me"),
		State:     onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host", "created": "2026-10-02T05:35:28Z"}),
		OldInputs: onideltest.BuildProps(old),
		Inputs:    onideltest.BuildProps(map[string]any{"name": "me-2", "publicKey": "ssh-ed25519 BBBB me@host"}),
	})

	require.NoError(t, err)
	assert.Equal(t, p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{
		"name":      {Kind: p.Update},
		"publicKey": {Kind: p.Update},
	}}, diff)
}

func TestSSHKeyUpdateSendsTheWholeKeyToTheTeam(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
	urn := onideltest.BuildURN("onidel:index:SshKey", "me")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}),
	})
	require.NoError(t, err)

	updated, err := ctx.server.Update(p.UpdateRequest{
		ID: created.ID, Urn: urn, State: created.Properties,
		OldInputs: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}),
		Inputs:    onideltest.BuildProps(map[string]any{"name": "me-2", "publicKey": "ssh-ed25519 BBBB me@host"}),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{"name": "me-2", "publicKey": "ssh-ed25519 BBBB me@host", "created": "2026-10-02T05:35:28Z"},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "POST", Path: "/ssh_keys", Body: map[string]any{"team_id": "team-a", "name": "me", "ssh_key": "ssh-ed25519 AAAA me@host"}},
			{Method: "PATCH", Path: "/ssh_keys/" + created.ID, Body: map[string]any{
				"team_id": "team-a", "name": "me-2", "ssh_key": "ssh-ed25519 BBBB me@host",
			}},
		},
	}, []any{onideltest.ToPlain(updated.Properties), ctx.api.GetRequests()})
}

func TestSSHKeyUpdatePreviewSendsNothing(t *testing.T) {
	ctx := setupTest(t)

	updated, err := ctx.server.Update(p.UpdateRequest{
		ID: "k", Urn: onideltest.BuildURN("onidel:index:SshKey", "me"),
		State:     onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host", "created": "2026-10-02T05:35:28Z"}),
		OldInputs: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}),
		Inputs:    onideltest.BuildProps(map[string]any{"name": "me-2", "publicKey": "ssh-ed25519 AAAA me@host"}),
		DryRun:    true,
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{"name": "me-2", "publicKey": "ssh-ed25519 AAAA me@host", "created": presource.Computed{Element: presource.NewProperty("")}},
		[]onideltest.Request(nil),
	}, []any{onideltest.ToPlain(updated.Properties), ctx.api.GetRequests()})
}

func TestSSHKeyUpdateFailsWhenTheKeySeesNoTeam(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams()

	_, err := ctx.server.Update(p.UpdateRequest{
		ID: "k", Urn: onideltest.BuildURN("onidel:index:SshKey", "me"),
		State:     onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host", "created": "2026-10-02T05:35:28Z"}),
		OldInputs: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}),
		Inputs:    onideltest.BuildProps(map[string]any{"name": "me-2", "publicKey": "ssh-ed25519 AAAA me@host"}),
	})

	assert.EqualError(t, err, "onidel: the API key can see 0 teams; set the teamId config")
}

func TestSSHKeyDeleteRemovesTheKeyFromTheTeam(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
	urn := onideltest.BuildURN("onidel:index:SshKey", "me")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}),
	})
	require.NoError(t, err)

	err = ctx.server.Delete(p.DeleteRequest{ID: created.ID, Urn: urn, Properties: created.Properties})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]map[string]any{},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "POST", Path: "/ssh_keys", Body: map[string]any{"team_id": "team-a", "name": "me", "ssh_key": "ssh-ed25519 AAAA me@host"}},
			{Method: "DELETE", Path: "/ssh_keys/" + created.ID, Query: "team_id=team-a"},
		},
	}, []any{ctx.api.GetSSHKeys(), ctx.api.GetRequests()})
}

func TestSSHKeyDeleteAcceptsAKeyThatIsAlreadyGone(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})

	err := ctx.server.Delete(p.DeleteRequest{ID: "missing", Urn: onideltest.BuildURN("onidel:index:SshKey", "me"),
		Properties: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host", "created": "2026-10-02T05:35:28Z"}),
	})

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/teams"}, {Method: "DELETE", Path: "/ssh_keys/missing", Query: "team_id=team-a"}}, ctx.api.GetRequests())
}

func TestSSHKeyDeleteFailsWhenTheAPIRefuses(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("DELETE /ssh_keys/{id}", http.StatusUnauthorized, "", 1)

	err := ctx.server.Delete(p.DeleteRequest{ID: "k", Urn: onideltest.BuildURN("onidel:index:SshKey", "me"),
		Properties: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host", "created": "2026-10-02T05:35:28Z"}),
	})

	assert.EqualError(t, err, "onidel: DELETE /ssh_keys/k: HTTP 401")
}

func TestSSHKeyCreateFailsWhenTheAPIRefuses(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
	ctx.api.RegisterResponse("POST /ssh_keys", http.StatusBadRequest, "", 1)

	_, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:SshKey", "me"),
		Properties: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}),
	})

	assert.EqualError(t, err, "onidel: POST /ssh_keys: HTTP 400")
}

func TestSSHKeyReadFailsWhenTheAPIFails(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /ssh_keys/{id}", http.StatusInternalServerError, "", 1)

	_, err := ctx.server.Read(p.ReadRequest{ID: "k", Urn: onideltest.BuildURN("onidel:index:SshKey", "me")})

	assert.EqualError(t, err, "onidel: GET /ssh_keys/k: HTTP 500")
}

func TestSSHKeyUpdateFailsForAKeyThatIsGone(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})

	_, err := ctx.server.Update(p.UpdateRequest{
		ID: "missing", Urn: onideltest.BuildURN("onidel:index:SshKey", "me"),
		State:     onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host", "created": "2026-10-02T05:35:28Z"}),
		OldInputs: onideltest.BuildProps(map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAA me@host"}),
		Inputs:    onideltest.BuildProps(map[string]any{"name": "me-2", "publicKey": "ssh-ed25519 AAAA me@host"}),
	})

	assert.EqualError(t, err, "onidel: PATCH /ssh_keys/missing: HTTP 404")
}
