package client

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const fixturePassword = "fixture-root-pw-do-not-leak"

const vmFixture = `{
  "id": "0f289413-258f-4115-ac81-252000998fe0", "name": "geoffcloud", "vcpu": 8, "ram": 32768,
  "disk": 240, "location": "Melbourne", "password": "` + fixturePassword + `",
  "main_ipv4": "203.0.113.18", "main_ipv6": "2001:db8::", "template": "Ubuntu 26.04 LTS x64",
  "firewall_group_id": null, "bgp_enabled": false, "status": "active", "active_action_id": null
}`

func setupClient(t *testing.T, h http.HandlerFunc) *Client {
	t.Helper()
	server := httptest.NewServer(h)
	t.Cleanup(server.Close)
	c := New(server.URL, "test-key")
	c.PollInterval = time.Millisecond
	return c
}

func TestReadVMDropsPassword(t *testing.T) {
	c := setupClient(t, func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "Bearer test-key", r.Header.Get("Authorization"))
		fmt.Fprint(w, vmFixture)
	})
	vm, err := c.ReadVM(context.Background(), "0f289413-258f-4115-ac81-252000998fe0", "")
	require.NoError(t, err)
	assert.Equal(t, "geoffcloud", vm.Name)
	assert.Equal(t, "Melbourne", vm.Location)
	assert.Empty(t, vm.FirewallGroupID)
	assert.False(t, vm.hasActiveAction())

	encoded, err := json.Marshal(vm)
	require.NoError(t, err)
	assert.NotContains(t, string(encoded), fixturePassword)
	assert.NotContains(t, fmt.Sprintf("%+v", vm), fixturePassword)
}

func TestAPIErrorOmitsBody(t *testing.T) {
	c := setupClient(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprint(w, `{"err":"SEV_NOT_SUPPORTED","password":"`+fixturePassword+`"}`)
	})
	_, err := c.ReadVM(context.Background(), "x", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "HTTP 400: SEV_NOT_SUPPORTED")
	assert.NotContains(t, err.Error(), fixturePassword)
}

func TestIsNotFound(t *testing.T) {
	c := setupClient(t, func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNotFound) })
	_, err := c.ReadVM(context.Background(), "x", "team")
	assert.True(t, IsNotFound(err))
}

func TestCreateVMFindsIDByListing(t *testing.T) {
	lists := 0
	c := setupClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/vm":
			lists++
			if lists == 1 {
				fmt.Fprint(w, `[{"id":"old","name":"web","created_at":"2026-01-01T00:00:00Z"}]`)
				return
			}
			fmt.Fprint(w, `[{"id":"old","name":"web","created_at":"2026-01-01T00:00:00Z"},
				{"id":"other","name":"db","created_at":"2026-10-02T00:00:00Z"},
				{"id":"new","name":"web","created_at":"2026-10-02T00:00:00Z","password":"`+fixturePassword+`"}]`)
		case r.Method == http.MethodPost && r.URL.Path == "/vm":
			w.WriteHeader(http.StatusCreated)
		case r.Method == http.MethodGet && r.URL.Path == "/vm/new":
			fmt.Fprint(w, strings.Replace(vmFixture, `"0f289413-258f-4115-ac81-252000998fe0"`, `"new"`, 1))
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
	})
	vm, err := c.CreateVM(context.Background(), VMInput{Name: "web", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20})
	require.NoError(t, err)
	assert.Equal(t, "new", vm.ID)
}

func TestFindCreatedID(t *testing.T) {
	assert.Equal(t, "a", findCreatedID([]byte(`{"id":"a","password":"x"}`)))
	assert.Equal(t, "b", findCreatedID([]byte(`{"vm":{"id":"b"}}`)))
	assert.Equal(t, "c", findCreatedID([]byte(`{"vm_id":"c"}`)))
	assert.Empty(t, findCreatedID(nil))
	assert.Empty(t, findCreatedID([]byte(`not json`)))
}

func TestWaitForVMReadyFailsOnTerminalStatus(t *testing.T) {
	c := setupClient(t, func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"id":"x","status":"awaiting_payment"}`)
	})
	_, err := c.WaitForVMReady(context.Background(), "x", "")
	require.ErrorContains(t, err, "awaiting_payment")
}

func TestSendRequestRetriesIdempotentRequestsOn503(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls++
		if calls < 3 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte(`[]`))
	}))
	defer srv.Close()
	c := New(srv.URL, "key")
	c.RetryBase = time.Millisecond

	if _, err := c.ReadTeams(context.Background()); err != nil {
		t.Fatalf("ReadTeams after two 503s: %v", err)
	}
	if calls != 3 {
		t.Fatalf("calls = %d, want 3", calls)
	}
}

func TestSendRequestNeverRetriesAPost(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls++
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer srv.Close()
	c := New(srv.URL, "key")
	c.RetryBase = time.Millisecond

	if _, err := c.CreateFirewallGroup(context.Background(), FirewallGroupInput{Description: "x"}); err == nil {
		t.Fatal("CreateFirewallGroup succeeded on 503")
	}
	if calls != 1 {
		t.Fatalf("calls = %d, want 1", calls)
	}
}
