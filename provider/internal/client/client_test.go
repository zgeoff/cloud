package client_test

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

// setupTest starts the fake API and a client for it. Go allows one setupTest per
// package, so this one serves every test file in the package.
func setupTest(t *testing.T) struct {
	api    *onideltest.FakeAPI
	client *client.Client
} {
	t.Helper()
	api := onideltest.StartFakeAPI(t)
	t.Cleanup(func() { assert.Empty(t, api.GetProblems(), "the fake API saw requests it does not serve") })
	c := client.New(api.URL, onideltest.APIKey)
	// The wait and retry helpers sleep on the wall clock; keep each sleep short.
	c.PollInterval = time.Millisecond
	c.RetryBase = time.Millisecond
	return struct {
		api    *onideltest.FakeAPI
		client *client.Client
	}{api: api, client: c}
}

func TestNewStartsWithTheDefaultIntervals(t *testing.T) {
	c := client.New("", "key")

	assert.Equal(t, []time.Duration{client.DefaultPollInterval, 500 * time.Millisecond}, []time.Duration{c.PollInterval, c.RetryBase})
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

func TestReadVMReportsAMissingVMAsNotFound(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.client.ReadVM(t.Context(), "x", "team")

	assert.True(t, client.IsNotFound(err))
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
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.RegisterHandler("GET /vm/{id}", func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = w.Write([]byte(row.body))
			})

			_, err := ctx.client.ReadVM(t.Context(), "x", "")

			var apiErr *client.APIError
			require.ErrorAs(t, err, &apiErr)
			assert.Equal(t, &client.APIError{Method: "GET", Path: "/vm/x", Status: 400, Code: row.want}, apiErr)
		})
	}
}

func TestClientReportsAMalformedPayloadWithoutItsContent(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterHandler("GET /teams", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`not json`))
	})

	_, err := ctx.client.ReadTeams(t.Context())

	assert.EqualError(t, err, "onidel: decode GET /teams: invalid character 'o' in literal null (expecting 'u')")
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
			var calls atomic.Int32
			ctx.api.RegisterHandler("GET /teams", func(w http.ResponseWriter, _ *http.Request) {
				if calls.Add(1) < 3 {
					w.WriteHeader(row.status)
					return
				}
				_, _ = w.Write([]byte(`[{"id":"t","name":"team","role":"Team Owner"}]`))
			})

			teams, err := ctx.client.ReadTeams(t.Context())

			require.NoError(t, err)
			assert.Equal(t, []client.Team{{ID: "t", Name: "team", Role: "Team Owner"}}, teams)
			assert.Equal(t, []onideltest.Request{
				{Method: "GET", Path: "/teams"}, {Method: "GET", Path: "/teams"}, {Method: "GET", Path: "/teams"},
			}, ctx.api.GetRequests())
		})
	}
}

func TestClientRetriesAPUTAndADELETE(t *testing.T) {
	rows := []struct {
		name    string
		pattern string
		call    func(ctx context.Context, c *client.Client) error
		request onideltest.Request
	}{
		{"it retries a PUT", "PUT /network/firewalls/{id}", func(ctx context.Context, c *client.Client) error {
			return c.UpdateFirewallGroup(ctx, "g", client.FirewallGroupInput{Description: "d"})
		}, onideltest.Request{Method: "PUT", Path: "/network/firewalls/g", Body: map[string]any{"description": "d"}}},
		{"it retries a DELETE", "DELETE /ssh_keys/{id}", func(ctx context.Context, c *client.Client) error {
			return c.RemoveSSHKey(ctx, "k", "t")
		}, onideltest.Request{Method: "DELETE", Path: "/ssh_keys/k", Query: "team_id=t"}},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			var calls atomic.Int32
			ctx.api.RegisterHandler(row.pattern, func(w http.ResponseWriter, _ *http.Request) {
				if calls.Add(1) < 2 {
					w.WriteHeader(http.StatusServiceUnavailable)
					return
				}
				w.WriteHeader(http.StatusNoContent)
			})

			err := row.call(t.Context(), ctx.client)

			require.NoError(t, err)
			assert.Equal(t, []onideltest.Request{row.request, row.request}, ctx.api.GetRequests())
		})
	}
}

func TestClientGivesUpAfterFourRetries(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterHandler("GET /teams", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	})

	_, err := ctx.client.ReadTeams(t.Context())

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "GET", Path: "/teams", Status: 503}, apiErr)
	assert.Equal(t, []onideltest.Request{
		{Method: "GET", Path: "/teams"}, {Method: "GET", Path: "/teams"}, {Method: "GET", Path: "/teams"},
		{Method: "GET", Path: "/teams"}, {Method: "GET", Path: "/teams"},
	}, ctx.api.GetRequests())
}

func TestClientNeverRetriesAWriteThatIsNotIdempotent(t *testing.T) {
	rows := []struct {
		name    string
		pattern string
		call    func(ctx context.Context, c *client.Client) error
		want    *client.APIError
	}{
		{"it never retries a POST", "POST /network/firewalls", func(ctx context.Context, c *client.Client) error {
			_, err := c.CreateFirewallGroup(ctx, client.FirewallGroupInput{TeamID: "t", Description: "x"})
			return err
		}, &client.APIError{Method: "POST", Path: "/network/firewalls", Status: 503}},
		{"it never retries a PATCH", "PATCH /ssh_keys/{id}", func(ctx context.Context, c *client.Client) error {
			return c.UpdateSSHKey(ctx, "k", client.SSHKeyInput{TeamID: "t", Name: "n", PublicKey: "p"})
		}, &client.APIError{Method: "PATCH", Path: "/ssh_keys/k", Status: 503}},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.RegisterHandler(row.pattern, func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusServiceUnavailable)
			})

			err := row.call(t.Context(), ctx.client)

			var apiErr *client.APIError
			require.ErrorAs(t, err, &apiErr)
			assert.Equal(t, row.want, apiErr)
			assert.Len(t, ctx.api.GetRequests(), 1)
		})
	}
}

func TestClientNeverRetriesAServerError(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterHandler("GET /teams", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	})

	_, err := ctx.client.ReadTeams(t.Context())

	var apiErr *client.APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, &client.APIError{Method: "GET", Path: "/teams", Status: 500}, apiErr)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/teams"}}, ctx.api.GetRequests())
}

func TestClientStopsRetryingWhenTheContextEnds(t *testing.T) {
	ctx := setupTest(t)
	callCtx, cancel := context.WithCancel(t.Context())
	t.Cleanup(cancel)
	ctx.api.RegisterHandler("GET /teams", func(w http.ResponseWriter, _ *http.Request) {
		cancel()
		w.WriteHeader(http.StatusServiceUnavailable)
	})
	ctx.client.RetryBase = time.Hour

	_, err := ctx.client.ReadTeams(callCtx)

	require.ErrorIs(t, err, context.Canceled)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/teams"}}, ctx.api.GetRequests())
}
