package onideltest_test

import (
	"net/http"
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestSendRequestSendsTheBodyWithTheStubsBearerToken(t *testing.T) {
	api := onideltest.StartStubOnidelAPI(t)

	status, body := onideltest.SendRequest(t, api.URL, "POST", "/network/firewalls", `{"team_id":"t","description":"edge"}`)

	assert.Equal(t, []any{
		http.StatusCreated,
		`{"firewall_group":{"created":"2026-10-02T00:00:00Z","description":"edge","id":"00000000-0000-4000-8000-000000000001",` +
			`"instance_count":0,"rule_count":0,"updated":"2026-10-02T00:00:00Z"}}` + "\n",
		[]onideltest.Request{{Method: "POST", Path: "/network/firewalls", Body: map[string]any{"team_id": "t", "description": "edge"}}},
	}, []any{status, body, api.GetRequests()})
}

func TestSendRequestSendsNoBodyForAnEmptyOne(t *testing.T) {
	api := onideltest.StartStubOnidelAPI(t)

	status, _ := onideltest.SendRequest(t, api.URL, "GET", "/vm?team_id=t", "")

	assert.Equal(t, []any{http.StatusOK, []onideltest.Request{{Method: "GET", Path: "/vm", Query: "team_id=t"}}},
		[]any{status, api.GetRequests()})
}
