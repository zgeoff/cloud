package client_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestUpdateRDNSSetsThePTRRecordForAnIP(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18"})

	err := ctx.client.UpdateRDNS(t.Context(), "v", "team-a", "203.0.113.18", "geoff.cloud")

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]map[string]string{"v": {"203.0.113.18": "geoff.cloud"}},
		[]onideltest.Request{{Method: "POST", Path: "/vm/v/rdns", Body: map[string]any{
			"team_id": "team-a", "ip_addr": "203.0.113.18", "domain": "geoff.cloud",
		}}},
	}, []any{ctx.api.GetRDNS(), ctx.api.GetRequests()})
}

func TestUpdateRDNSFailsForAnIPTheVMDoesNotOwn(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18"})

	err := ctx.client.UpdateRDNS(t.Context(), "v", "", "198.51.100.1", "geoff.cloud")

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "POST", Path: "/vm/v/rdns", Status: 401}, apiErr)
}

func TestReadRDNSListsTheVMsPTRRecords(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18", "main_ipv6": "2001:db8::1"})
	require.NoError(t, ctx.client.UpdateRDNS(t.Context(), "v", "", "203.0.113.18", "geoff.cloud"))
	require.NoError(t, ctx.client.UpdateRDNS(t.Context(), "v", "", "2001:db8::1", "v6.geoff.cloud"))

	records, err := ctx.client.ReadRDNS(t.Context(), "v", "team-a")

	require.NoError(t, err)
	assert.Equal(t, []client.RDNSRecord{{IP: "2001:db8::1", Domain: "v6.geoff.cloud"}, {IP: "203.0.113.18", Domain: "geoff.cloud"}}, records)
}

func TestRemoveRDNSRemovesThePTRRecordForAnIP(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv6": "2001:db8::1"})
	require.NoError(t, ctx.client.UpdateRDNS(t.Context(), "v", "", "2001:db8::1", "v6.geoff.cloud"))

	err := ctx.client.RemoveRDNS(t.Context(), "v", "team-a", "2001:db8::1")

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]map[string]string{"v": {}},
		[]onideltest.Request{
			{Method: "POST", Path: "/vm/v/rdns", Body: map[string]any{"ip_addr": "2001:db8::1", "domain": "v6.geoff.cloud"}},
			{Method: "DELETE", Path: "/vm/v/rdns/2001:db8::1", Query: "team_id=team-a"},
		},
	}, []any{ctx.api.GetRDNS(), ctx.api.GetRequests()})
}
