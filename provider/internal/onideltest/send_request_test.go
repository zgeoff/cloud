package onideltest_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestSendRequestSendsTheBodyWithTheStubsBearerToken(t *testing.T) {
	ctx := setupTest(t)

	status, body := onideltest.SendRequest(t, ctx.api.URL, "POST", "/network/firewalls", `{"team_id":"t","description":"edge"}`)

	assert.Equal(t, []any{
		http.StatusCreated,
		`{"firewall_group":{"created":"2026-10-02T00:00:00Z","description":"edge","id":"00000000-0000-4000-8000-000000000001",` +
			`"instance_count":0,"rule_count":0,"updated":"2026-10-02T00:00:00Z"}}` + "\n",
	}, []any{status, body})
	assert.Equal(t, []onideltest.Request{{Method: "POST", Path: "/network/firewalls", Body: map[string]any{"team_id": "t", "description": "edge"}}}, ctx.api.GetRequests())
}

func TestSendRequestSendsNoBodyForAnEmptyOne(t *testing.T) {
	ctx := setupTest(t)

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "GET", "/vm?team_id=t", "")

	assert.Equal(t, http.StatusOK, status)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/vm", Query: "team_id=t"}}, ctx.api.GetRequests())
}

func TestSendRequestFailsTheTestOnATransportError(t *testing.T) {
	stub := onideltest.BuildStubTB(t)
	server := httptest.NewServer(http.NotFoundHandler())
	server.Close()
	reached := false

	stub.Run(func() {
		onideltest.SendRequest(stub, server.URL, "GET", "/teams", "")
		reached = true
	})

	errs := stub.GetErrors()
	require.Len(t, errs, 1)
	assert.False(t, reached)
	assert.True(t, stub.Failed())
	assert.Contains(t, errs[0], "connect: connection refused")
}
