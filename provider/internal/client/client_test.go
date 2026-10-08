package client_test

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"syscall"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/clienttest"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

// setupTest starts the stub API and a client for it. Go allows one setupTest per
// package, so this one serves every test file in the package.
// The client's sleeps return at once and are recorded in sleep, in order.
func setupTest(t *testing.T) struct {
	api    *onideltest.StubOnidelAPI
	client *client.Client
	sleep  *onideltest.StubSleep
} {
	t.Helper()
	api := onideltest.StartStubOnidelAPI(t)
	c := client.New(api.URL, onideltest.APIKey)
	sleep := onideltest.BuildStubSleep()
	c.Sleep = sleep.Sleep
	return struct {
		api    *onideltest.StubOnidelAPI
		client *client.Client
		sleep  *onideltest.StubSleep
	}{api: api, client: c, sleep: sleep}
}

func TestNewStartsWithTheDefaultIntervals(t *testing.T) {
	c := client.New("", "key")

	assert.Equal(t, 10*time.Second, c.PollInterval)
	assert.Equal(t, 500*time.Millisecond, c.RetryBase)
	assert.Equal(t, 30*time.Minute, c.VMWaitTimeout)
}

func TestNewSleepsForTheWholeDuration(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := client.New("", "key")
		start := time.Now()

		err := c.Sleep(t.Context(), time.Hour)

		require.NoError(t, err)
		assert.Equal(t, time.Hour, time.Since(start))
	})
}

func TestNewSleepsNoLongerThanTheContextLasts(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := client.New("", "key")
		sleepCtx, cancel := context.WithCancel(t.Context())
		t.Cleanup(cancel)
		go func() {
			time.Sleep(time.Minute)
			cancel()
		}()
		start := time.Now()

		err := c.Sleep(sleepCtx, time.Hour)

		assert.Equal(t, context.Canceled, err)
		assert.Equal(t, time.Minute, time.Since(start))
	})
}

func TestNewTrimsATrailingSlashFromTheBaseURL(t *testing.T) {
	ctx := setupTest(t)
	c := client.New(ctx.api.URL+"/", onideltest.APIKey)

	_, err := c.ReadTeams(t.Context())

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/teams"}}, ctx.api.GetRequests())
}

func TestAPIErrorNamesTheRequestStatusAndCode(t *testing.T) {
	rows := []struct {
		name string
		err  *client.APIError
		want string
	}{
		{"it appends the code", &client.APIError{Method: "PATCH", Path: "/vm/x", Status: 400, Code: "SEV_NOT_SUPPORTED"}, "onidel: PATCH /vm/x: HTTP 400: SEV_NOT_SUPPORTED"},
		{"it omits an empty code", &client.APIError{Method: "GET", Path: "/vm/x", Status: 404}, "onidel: GET /vm/x: HTTP 404"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			assert.EqualError(t, row.err, row.want)
		})
	}
}

func TestIsNotFoundRecognisesOnlyAnAPI404(t *testing.T) {
	rows := []struct {
		name string
		err  error
		want bool
	}{
		{"it accepts an API 404", &client.APIError{Method: "GET", Path: "/vm/x", Status: 404}, true},
		{"it accepts a wrapped API 404", fmt.Errorf("read: %w", &client.APIError{Status: 404}), true},
		{"it rejects another API status", &client.APIError{Status: 500}, false},
		{"it rejects an error that is not an API error", errors.New("HTTP 404"), false},
		{"it rejects nil", nil, false},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			assert.Equal(t, row.want, client.IsNotFound(row.err))
		})
	}
}

func TestClientFailsWithAnAPIErrorForAWrongKey(t *testing.T) {
	ctx := setupTest(t)
	c := client.New(ctx.api.URL, "other-key")

	_, err := c.ReadTeams(t.Context())

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "GET", Path: "/teams", Status: 401}, apiErr)
}

func TestClientKeepsOnlyTheErrorCodeFromAnErrorBody(t *testing.T) {
	rows := []struct {
		name string
		body string
		want string
	}{
		{"it reads the documented err field", `{"err":"SEV_NOT_SUPPORTED","password":"fixture-root-pw-do-not-leak"}`, "SEV_NOT_SUPPORTED"},
		{"it reads an error field", `{"error":"NOT_ALLOWED"}`, "NOT_ALLOWED"},
		{"it reads a message field", `{"message":"bad request"}`, "bad request"},
		{"it prefers err over error and message", `{"message":"m","error":"e","err":"E"}`, "E"},
		{"it skips a field that is not a string", `{"err":{"code":1},"message":"m"}`, "m"},
		{"it truncates a long code to 200 characters", `{"err":"` + strings.Repeat("x", 300) + `"}`, strings.Repeat("x", 200)},
		{"it drops a body that is not JSON", `<html>fixture-root-pw-do-not-leak</html>`, ""},
		{"it drops an empty body", ``, ""},
		{"it drops a JSON body with no code", `{}`, ""},
		{"it drops an empty code", `{"err":""}`, ""},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.RegisterResponse("GET /vm/{id}", http.StatusBadRequest, row.body, 1)

			_, err := ctx.client.ReadVM(t.Context(), "x", "")

			var apiErr *client.APIError
			require.ErrorAs(t, err, &apiErr)
			assert.Equal(t, &client.APIError{Method: "GET", Path: "/vm/x", Status: 400, Code: row.want}, apiErr)
		})
	}
}

func TestClientReportsAMalformedPayloadWithoutItsContent(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /teams", http.StatusOK, `not json`, 1)

	_, err := ctx.client.ReadTeams(t.Context())

	assert.EqualError(t, err, "onidel: decode GET /teams: invalid character 'o' in literal null (expecting 'u')")
}

func TestClientReportsAResponseBodyThatEndsEarly(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterHandler("GET /teams", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", "100")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("[]"))
	})

	_, err := ctx.client.ReadTeams(t.Context())

	require.ErrorIs(t, err, io.ErrUnexpectedEOF)
	assert.EqualError(t, err, "onidel: GET /teams: read body: unexpected EOF")
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/teams"}}, ctx.api.GetRequests())
}

func TestClientReportsAnUnreachableAPI(t *testing.T) {
	server := httptest.NewServer(http.NotFoundHandler())
	server.Close()
	c := client.New(server.URL, "key")

	_, err := c.ReadTeams(t.Context())

	assert.ErrorIs(t, err, syscall.ECONNREFUSED)
}

func TestClientRetriesAGETOnATransientStatus(t *testing.T) {
	rows := []struct {
		name   string
		status int
	}{
		{"it retries after 429", http.StatusTooManyRequests},
		{"it retries after 502", http.StatusBadGateway},
		{"it retries after 503", http.StatusServiceUnavailable},
		{"it retries after 504", http.StatusGatewayTimeout},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
			ctx.api.RegisterResponse("GET /teams", row.status, "", 2)

			teams, err := ctx.client.ReadTeams(t.Context())

			require.NoError(t, err)
			assert.Equal(t, []client.Team{{ID: "team-a", Name: "team", Role: "Team Owner"}}, teams)
			assert.Equal(t, []onideltest.Request{
				{Method: "GET", Path: "/teams"}, {Method: "GET", Path: "/teams"}, {Method: "GET", Path: "/teams"},
			}, ctx.api.GetRequests())
			assert.Equal(t, []time.Duration{500 * time.Millisecond, time.Second}, ctx.sleep.GetDurations())
		})
	}
}

func TestClientRetriesAPUT(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g", "description": "c"})
	ctx.api.RegisterResponse("PUT /network/firewalls/{id}", http.StatusServiceUnavailable, "", 1)

	err := ctx.client.UpdateFirewallGroup(t.Context(), "g", clienttest.BuildMockFirewallGroupInput(func(in *client.FirewallGroupInput) {
		in.TeamID, in.Description = "", "d"
	}))

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{
		{Method: "PUT", Path: "/network/firewalls/g", Body: map[string]any{"description": "d"}},
		{Method: "PUT", Path: "/network/firewalls/g", Body: map[string]any{"description": "d"}},
	}, ctx.api.GetRequests())
	assert.Equal(t, []time.Duration{500 * time.Millisecond}, ctx.sleep.GetDurations())
}

func TestClientRetriesADELETE(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g", "instance_count": 0})
	ctx.api.RegisterResponse("DELETE /network/firewalls/{id}", http.StatusServiceUnavailable, "", 1)

	err := ctx.client.RemoveFirewallGroup(t.Context(), "g", "t")

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{
		{Method: "DELETE", Path: "/network/firewalls/g", Query: "team_id=t"},
		{Method: "DELETE", Path: "/network/firewalls/g", Query: "team_id=t"},
	}, ctx.api.GetRequests())
	assert.Equal(t, []time.Duration{500 * time.Millisecond}, ctx.sleep.GetDurations())
}

func TestClientGivesUpAfterFourRetries(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /teams", http.StatusServiceUnavailable, "", 5)

	_, err := ctx.client.ReadTeams(t.Context())

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "GET", Path: "/teams", Status: 503}, apiErr)
	assert.Equal(t, []onideltest.Request{
		{Method: "GET", Path: "/teams"}, {Method: "GET", Path: "/teams"}, {Method: "GET", Path: "/teams"},
		{Method: "GET", Path: "/teams"}, {Method: "GET", Path: "/teams"},
	}, ctx.api.GetRequests())
	assert.Equal(t, []time.Duration{500 * time.Millisecond, time.Second, 2 * time.Second, 4 * time.Second}, ctx.sleep.GetDurations())
}

func TestClientNeverRetriesAPOST(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("POST /network/firewalls", http.StatusServiceUnavailable, "", 1)

	_, err := ctx.client.CreateFirewallGroup(t.Context(), clienttest.BuildMockFirewallGroupInput(func(in *client.FirewallGroupInput) {
		in.TeamID, in.Description = "t", "x"
	}))

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "POST", Path: "/network/firewalls", Status: 503}, apiErr)
	assert.Equal(t, []onideltest.Request{
		{Method: "POST", Path: "/network/firewalls", Body: map[string]any{"team_id": "t", "description": "x"}},
	}, ctx.api.GetRequests())
	assert.Equal(t, []time.Duration(nil), ctx.sleep.GetDurations())
}

func TestClientNeverRetriesAPATCH(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("PATCH /ssh_keys/{id}", http.StatusServiceUnavailable, "", 1)

	err := ctx.client.UpdateSSHKey(t.Context(), "k", clienttest.BuildMockSSHKeyInput(func(in *client.SSHKeyInput) {
		in.TeamID, in.Name, in.PublicKey = "t", "n", "p"
	}))

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "PATCH", Path: "/ssh_keys/k", Status: 503}, apiErr)
	assert.Equal(t, []onideltest.Request{
		{Method: "PATCH", Path: "/ssh_keys/k", Body: map[string]any{"team_id": "t", "name": "n", "ssh_key": "p"}},
	}, ctx.api.GetRequests())
	assert.Equal(t, []time.Duration(nil), ctx.sleep.GetDurations())
}

func TestClientNeverRetriesAServerError(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /teams", http.StatusInternalServerError, "", 1)

	_, err := ctx.client.ReadTeams(t.Context())

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "GET", Path: "/teams", Status: 500}, apiErr)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/teams"}}, ctx.api.GetRequests())
	assert.Equal(t, []time.Duration(nil), ctx.sleep.GetDurations())
}

func TestClientStopsRetryingWhenTheContextEnds(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /teams", http.StatusServiceUnavailable, "", 1)
	callCtx, cancel := context.WithCancel(t.Context())
	t.Cleanup(cancel)
	ctx.client.Sleep = onideltest.BuildStubCancelingSleep(cancel).Sleep

	_, err := ctx.client.ReadTeams(callCtx)

	assert.Equal(t, context.Canceled, err)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/teams"}}, ctx.api.GetRequests())
}

func TestClientReportsABaseURLThatDoesNotParse(t *testing.T) {
	c := client.New("http://bad host", "key")

	_, err := c.ReadTeams(t.Context())

	var urlErr *url.Error
	require.ErrorAs(t, err, &urlErr)
	assert.Equal(t, &url.Error{Op: "parse", URL: "http://bad host/teams", Err: url.InvalidHostError(" ")}, urlErr)
}

func TestNewDefaultsToTheProductionAPI(t *testing.T) {
	c := client.New("", "key")
	canceled, cancel := context.WithCancel(t.Context())
	cancel()

	_, err := c.ReadTeams(canceled)

	assert.EqualError(t, err, `onidel: GET /teams: Get "https://api.cloud.onidel.com/teams": context canceled`)
}
