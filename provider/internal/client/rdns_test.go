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
	assert.Equal(t, map[string]map[string]string{"v": {"203.0.113.18": "example.com"}}, ctx.api.GetRDNS())
	assert.Equal(t, []onideltest.Request{{Method: "POST", Path: "/vm/v/rdns", Body: map[string]any{
		"team_id": "team-a", "ip_addr": "203.0.113.18", "domain": "example.com",
	}}}, ctx.api.GetRequests())
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
	ctx.api.SetRDNS("v", map[string]string{"203.0.113.18": "example.com", "2001:db8::1": "v6.example.com"})

	records, err := ctx.client.ReadRDNS(t.Context(), "v", "team-a")

	require.NoError(t, err)
	assert.Equal(t, []client.RDNSRecord{{IP: "2001:db8::1", Domain: "v6.example.com"}, {IP: "203.0.113.18", Domain: "example.com"}}, records)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/vm/v/rdns", Query: "team_id=team-a"}}, ctx.api.GetRequests())
}

func TestRemoveRDNSRemovesThePTRRecordForAnIP(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv6": "2001:db8::1"})
	ctx.api.SetRDNS("v", map[string]string{"2001:db8::1": "v6.example.com"})

	err := ctx.client.RemoveRDNS(t.Context(), "v", "team-a", "2001:db8::1")

	require.NoError(t, err)
	assert.Equal(t, map[string]map[string]string{"v": {}}, ctx.api.GetRDNS())
	assert.Equal(t, []onideltest.Request{{Method: "DELETE", Path: "/vm/v/rdns/2001:db8::1", Query: "team_id=team-a"}}, ctx.api.GetRequests())
}
