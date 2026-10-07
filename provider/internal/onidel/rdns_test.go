package onidel_test

import (
	"net/http"
	"testing"

	p "github.com/pulumi/pulumi-go-provider"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestRDNSCreateSetsThePTRRecordForTheVMsIP(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
	ctx.api.SetVM(map[string]any{"id": "0f289413-258f-4115-ac81-252000998fe0", "main_ipv4": "203.0.113.18", "main_ipv6": "2001:db8:4:17f::"})

	created, err := ctx.server.Create(p.CreateRequest{
		Urn: onideltest.BuildURN("onidel:index:Rdns", "v4"),
		Properties: onideltest.BuildProps(map[string]any{
			"vmId": "0f289413-258f-4115-ac81-252000998fe0", "ip": "203.0.113.18", "domain": "example.com",
		}),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		"0f289413-258f-4115-ac81-252000998fe0/203.0.113.18",
		map[string]any{"vmId": "0f289413-258f-4115-ac81-252000998fe0", "ip": "203.0.113.18", "domain": "example.com"},
		map[string]map[string]string{"0f289413-258f-4115-ac81-252000998fe0": {"203.0.113.18": "example.com"}},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "POST", Path: "/vm/0f289413-258f-4115-ac81-252000998fe0/rdns", Body: map[string]any{
				"team_id": "team-a", "ip_addr": "203.0.113.18", "domain": "example.com",
			}},
		},
	}, []any{created.ID, onideltest.ToPlain(created.Properties), ctx.api.GetRDNS(), ctx.api.GetRequests()})
}

func TestRDNSCreatePreviewSendsNothing(t *testing.T) {
	ctx := setupTest(t)

	created, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:Rdns", "v4"),
		Properties: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
		DryRun:     true,
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"},
		[]onideltest.Request(nil),
	}, []any{onideltest.ToPlain(created.Properties), ctx.api.GetRequests()})
}

func TestRDNSCreateFailsForAnIPTheVMDoesNotOwn(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18"})

	_, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:Rdns", "v4"),
		Properties: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "198.51.100.1", "domain": "example.com"}),
	})

	assert.EqualError(t, err, "onidel: POST /vm/v/rdns: HTTP 401")
}

func TestRDNSImportReadsTheRecordByCompositeID(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18"})
	urn := onideltest.BuildURN("onidel:index:Rdns", "v4")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
	})
	require.NoError(t, err)

	imported, err := ctx.server.Read(p.ReadRequest{ID: created.ID, Urn: urn})

	require.NoError(t, err)
	assert.Equal(t, []any{
		"v/203.0.113.18",
		map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"},
		map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"},
	}, []any{imported.ID, onideltest.ToPlain(imported.Inputs), onideltest.ToPlain(imported.Properties)})
}

func TestRDNSReadKeepsTheProgramsSpellingOfAnEquivalentDomain(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18"})
	urn := onideltest.BuildURN("onidel:index:Rdns", "v4")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
	})
	require.NoError(t, err)

	read, err := ctx.server.Read(p.ReadRequest{
		ID: created.ID, Urn: urn, Properties: created.Properties,
		Inputs: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "Example.Com."}),
	})

	require.NoError(t, err)
	assert.Equal(t, map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "Example.Com."}, onideltest.ToPlain(read.Inputs))
}

func TestRDNSReadReportsADomainChangedOutsideTheProgram(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18"})
	urn := onideltest.BuildURN("onidel:index:Rdns", "v4")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "other.example"}),
	})
	require.NoError(t, err)

	read, err := ctx.server.Read(p.ReadRequest{
		ID: created.ID, Urn: urn, Properties: created.Properties,
		Inputs: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
	})

	require.NoError(t, err)
	assert.Equal(t, map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "other.example"}, onideltest.ToPlain(read.Inputs))
}

func TestRDNSReadMatchesAnIPv6RecordWrittenInAnotherForm(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv6": "2001:db8::1"})
	urn := onideltest.BuildURN("onidel:index:Rdns", "v6")
	_, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "2001:db8::1", "domain": "example.com"}),
	})
	require.NoError(t, err)

	read, err := ctx.server.Read(p.ReadRequest{ID: "v/2001:0db8:0:0:0:0:0:1", Urn: urn})

	require.NoError(t, err)
	assert.Equal(t, []any{
		"v/2001:0db8:0:0:0:0:0:1",
		map[string]any{"vmId": "v", "ip": "2001:0db8:0:0:0:0:0:1", "domain": "example.com"},
	}, []any{read.ID, onideltest.ToPlain(read.Inputs)})
}

func TestRDNSReadReportsAMissingRecordAsGone(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18"})

	read, err := ctx.server.Read(p.ReadRequest{ID: "v/203.0.113.18", Urn: onideltest.BuildURN("onidel:index:Rdns", "v4")})

	require.NoError(t, err)
	assert.Equal(t, "", read.ID)
}

func TestRDNSReadReportsARecordWithAnEmptyDomainAsGone(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /vm/{id}/rdns", http.StatusOK, `{"rdns":[{"ip":"203.0.113.18","domain":""}]}`, 1)

	read, err := ctx.server.Read(p.ReadRequest{ID: "v/203.0.113.18", Urn: onideltest.BuildURN("onidel:index:Rdns", "v4")})

	require.NoError(t, err)
	assert.Equal(t, "", read.ID)
}

func TestRDNSReadReportsAMissingVMAsGone(t *testing.T) {
	ctx := setupTest(t)
	// The spec lists no 404 for GET /vm/{id}/rdns and none has been seen live; this
	// covers the not-found branch in RDNS.Read (rdns.go) that the code keeps anyway.
	ctx.api.RegisterResponse("GET /vm/{id}/rdns", http.StatusNotFound, "", 1)

	read, err := ctx.server.Read(p.ReadRequest{ID: "v/203.0.113.18", Urn: onideltest.BuildURN("onidel:index:Rdns", "v4")})

	require.NoError(t, err)
	assert.Equal(t, "", read.ID)
}

func TestRDNSReadFailsWhenTheAPIFails(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /vm/{id}/rdns", http.StatusForbidden, "", 1)

	_, err := ctx.server.Read(p.ReadRequest{ID: "v/203.0.113.18", Urn: onideltest.BuildURN("onidel:index:Rdns", "v4")})

	assert.EqualError(t, err, "onidel: GET /vm/v/rdns: HTTP 403")
}

func TestRDNSReadRejectsAMalformedID(t *testing.T) {
	rows := []struct {
		name string
		id   string
	}{
		{"it rejects an ID without a slash", "nope"},
		{"it rejects an ID without a VM", "/203.0.113.18"},
		{"it rejects an ID whose IP does not parse", "v/not-an-ip"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)

			_, err := ctx.server.Read(p.ReadRequest{ID: row.id, Urn: onideltest.BuildURN("onidel:index:Rdns", "r")})

			assert.EqualError(t, err, `onidel: rdns ID "`+row.id+`" is not <vmId>/<ip>`)
			assert.Equal(t, []onideltest.Request(nil), ctx.api.GetRequests())
		})
	}
}

func TestRDNSDeleteRejectsAMalformedID(t *testing.T) {
	ctx := setupTest(t)

	err := ctx.server.Delete(p.DeleteRequest{
		ID: "v/not-an-ip", Urn: onideltest.BuildURN("onidel:index:Rdns", "r"),
		Properties: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
	})

	assert.EqualError(t, err, `onidel: rdns ID "v/not-an-ip" is not <vmId>/<ip>`)
	assert.Equal(t, []onideltest.Request(nil), ctx.api.GetRequests())
}

func TestRDNSDiffUpdatesTheDomainInPlaceAndReplacesForANewIP(t *testing.T) {
	rows := []struct {
		name   string
		inputs map[string]any
		want   p.DiffResponse
	}{
		{
			"it updates a new domain in place",
			map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "host.example.com"},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"domain": {Kind: p.Update}}},
		},
		{
			"it replaces the record for a new IP",
			map[string]any{"vmId": "v", "ip": "2001:db8:4:17f::", "domain": "example.com"},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"ip": {Kind: p.UpdateReplace}}},
		},
		{
			"it replaces the record for a new VM",
			map[string]any{"vmId": "w", "ip": "203.0.113.18", "domain": "example.com"},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"vmId": {Kind: p.UpdateReplace}}},
		},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)

			diff, err := ctx.server.Diff(p.DiffRequest{
				ID: "v/203.0.113.18", Urn: onideltest.BuildURN("onidel:index:Rdns", "v4"),
				State:     onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
				OldInputs: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
				Inputs:    onideltest.BuildProps(row.inputs),
			})

			require.NoError(t, err)
			assert.Equal(t, row.want, diff)
		})
	}
}

func TestRDNSUpdateOverwritesTheRecord(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18"})
	urn := onideltest.BuildURN("onidel:index:Rdns", "v4")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
	})
	require.NoError(t, err)

	updated, err := ctx.server.Update(p.UpdateRequest{
		ID: created.ID, Urn: urn, State: created.Properties,
		OldInputs: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
		Inputs:    onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "host.example.com"}),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "host.example.com"},
		map[string]map[string]string{"v": {"203.0.113.18": "host.example.com"}},
	}, []any{onideltest.ToPlain(updated.Properties), ctx.api.GetRDNS()})
}

func TestRDNSUpdatePreviewSendsNothing(t *testing.T) {
	ctx := setupTest(t)

	updated, err := ctx.server.Update(p.UpdateRequest{
		ID: "v/203.0.113.18", Urn: onideltest.BuildURN("onidel:index:Rdns", "v4"),
		State:     onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
		OldInputs: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
		Inputs:    onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "host.example.com"}),
		DryRun:    true,
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "host.example.com"},
		[]onideltest.Request(nil),
	}, []any{onideltest.ToPlain(updated.Properties), ctx.api.GetRequests()})
}

func TestRDNSUpdateFailsWhenTheAPIRefuses(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.server.Update(p.UpdateRequest{
		ID: "v/203.0.113.18", Urn: onideltest.BuildURN("onidel:index:Rdns", "v4"),
		State:     onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
		OldInputs: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
		Inputs:    onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "host.example.com"}),
	})

	assert.EqualError(t, err, "onidel: POST /vm/v/rdns: HTTP 401")
}

func TestRDNSDeleteRemovesTheRecord(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18"})
	urn := onideltest.BuildURN("onidel:index:Rdns", "v4")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
	})
	require.NoError(t, err)

	err = ctx.server.Delete(p.DeleteRequest{ID: created.ID, Urn: urn, Properties: created.Properties})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]map[string]string{"v": {}},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "POST", Path: "/vm/v/rdns", Body: map[string]any{"team_id": "team-a", "ip_addr": "203.0.113.18", "domain": "example.com"}},
			{Method: "DELETE", Path: "/vm/v/rdns/203.0.113.18", Query: "team_id=team-a"},
		},
	}, []any{ctx.api.GetRDNS(), ctx.api.GetRequests()})
}

func TestRDNSDeleteAcceptsARecordWhoseVMIsGone(t *testing.T) {
	ctx := setupTest(t)
	// The spec lists no 404 for DELETE /vm/{id}/rdns/{ip} and none has been seen live;
	// this covers the not-found branch in RDNS.Delete (rdns.go) that the code keeps anyway.
	ctx.api.RegisterResponse("DELETE /vm/{id}/rdns/{ip}", http.StatusNotFound, "", 1)

	err := ctx.server.Delete(p.DeleteRequest{
		ID: "v/203.0.113.18", Urn: onideltest.BuildURN("onidel:index:Rdns", "v4"),
		Properties: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
	})

	assert.NoError(t, err)
}

func TestRDNSDeleteFailsWhenTheAPIRefuses(t *testing.T) {
	ctx := setupTest(t)

	err := ctx.server.Delete(p.DeleteRequest{
		ID: "v/203.0.113.18", Urn: onideltest.BuildURN("onidel:index:Rdns", "v4"),
		Properties: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
	})

	assert.EqualError(t, err, "onidel: DELETE /vm/v/rdns/203.0.113.18: HTTP 401")
}

func TestRDNSReadAfterDeleteReportsTheRecordAsGone(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18"})
	urn := onideltest.BuildURN("onidel:index:Rdns", "v4")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"vmId": "v", "ip": "203.0.113.18", "domain": "example.com"}),
	})
	require.NoError(t, err)
	require.NoError(t, ctx.server.Delete(p.DeleteRequest{ID: created.ID, Urn: urn, Properties: created.Properties}))

	read, err := ctx.server.Read(p.ReadRequest{ID: created.ID, Urn: urn})

	require.NoError(t, err)
	assert.Equal(t, "", read.ID)
}
