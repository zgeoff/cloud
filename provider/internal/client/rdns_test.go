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

	err := ctx.client.UpdateRDNS(t.Context(), "v", "team-a", "203.0.113.18", "example.com")

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]map[string]string{"v": {"203.0.113.18": "example.com"}},
		[]onideltest.Request{{Method: "POST", Path: "/vm/v/rdns", Body: map[string]any{
			"team_id": "team-a", "ip_addr": "203.0.113.18", "domain": "example.com",
		}}},
	}, []any{ctx.api.GetRDNS(), ctx.api.GetRequests()})
}

func TestUpdateRDNSFailsForAnIPTheVMDoesNotOwn(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18"})

	err := ctx.client.UpdateRDNS(t.Context(), "v", "", "198.51.100.1", "example.com")

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "POST", Path: "/vm/v/rdns", Status: 401}, apiErr)
}

func TestReadRDNSListsTheVMsPTRRecords(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18", "main_ipv6": "2001:db8::1"})
	require.NoError(t, ctx.client.UpdateRDNS(t.Context(), "v", "", "203.0.113.18", "example.com"))
	require.NoError(t, ctx.client.UpdateRDNS(t.Context(), "v", "", "2001:db8::1", "v6.example.com"))

	records, err := ctx.client.ReadRDNS(t.Context(), "v", "team-a")

	require.NoError(t, err)
	assert.Equal(t, []client.RDNSRecord{{IP: "2001:db8::1", Domain: "v6.example.com"}, {IP: "203.0.113.18", Domain: "example.com"}}, records)
}

func TestRemoveRDNSRemovesThePTRRecordForAnIP(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv6": "2001:db8::1"})
	require.NoError(t, ctx.client.UpdateRDNS(t.Context(), "v", "", "2001:db8::1", "v6.example.com"))

	err := ctx.client.RemoveRDNS(t.Context(), "v", "team-a", "2001:db8::1")

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]map[string]string{"v": {}},
		[]onideltest.Request{
			{Method: "POST", Path: "/vm/v/rdns", Body: map[string]any{"ip_addr": "2001:db8::1", "domain": "v6.example.com"}},
			{Method: "DELETE", Path: "/vm/v/rdns/2001:db8::1", Query: "team_id=team-a"},
		},
	}, []any{ctx.api.GetRDNS(), ctx.api.GetRequests()})
}
