// Package client is the provider's policy on top of the generated Onidel client in
// internal/onidelapi: retries with an injected sleep, error mapping, and the waits for a
// VM to settle. Requests and responses use onidelapi's generated types.
//
// Security: the API returns a VM's root password in plain text. No onidelapi type has a
// field for it, so it is dropped at decode time, and no function here logs or formats a
// response body.
package client

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

// DefaultBaseURL is the production Onidel API.
const DefaultBaseURL = "https://api.cloud.onidel.com"

const (
	maxResponseBytes = 4 << 20
	maxErrorDetail   = 200
)

// DefaultPollInterval is the PollInterval New gives a client.
const DefaultPollInterval = 10 * time.Second

// DefaultVMWaitTimeout is the VMWaitTimeout New gives a client.
const DefaultVMWaitTimeout = 30 * time.Minute

// Client talks to the Onidel API with a bearer token.
type Client struct {
	api  *onidelapi.Client
	http *http.Client
	// PollInterval is how long the wait helpers sleep between reads.
	PollInterval time.Duration
	// RetryBase is the first backoff for a retried request; it doubles per retry.
	RetryBase time.Duration
	// VMWaitTimeout caps how long the VM helpers wait for the API to settle.
	VMWaitTimeout time.Duration
	// Sleep waits d between polls and retries. It returns ctx's error, and stops
	// waiting, when ctx ends first.
	Sleep func(ctx context.Context, d time.Duration) error
}

// New returns a client for baseURL (DefaultBaseURL when empty).
func New(baseURL, apiKey string) *Client {
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	c := &Client{
		http:          &http.Client{Timeout: 60 * time.Second},
		PollInterval:  DefaultPollInterval,
		RetryBase:     500 * time.Millisecond,
		VMWaitTimeout: DefaultVMWaitTimeout,
		Sleep:         sleepContext,
	}
	// NewClient fails only when an option does, and neither of these can.
	c.api, _ = onidelapi.NewClient(baseURL,
		onidelapi.WithHTTPClient(retryingDoer{c}),
		onidelapi.WithRequestEditorFn(func(_ context.Context, req *http.Request) error {
			req.Header.Set("Authorization", "Bearer "+apiKey)
			req.Header.Set("Accept", "application/json")
			return nil
		}),
	)
	return c
}

// sleepContext waits d, or returns ctx's error as soon as ctx ends.
func sleepContext(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// APIError is a non-2xx response. It carries the status and the API's short error
// code, never the raw body.
type APIError struct {
	Method string
	Path   string
	Status int
	Code   string
}

func (e *APIError) Error() string {
	msg := fmt.Sprintf("onidel: %s %s: HTTP %d", e.Method, e.Path, e.Status)
	if e.Code != "" {
		msg += ": " + e.Code
	}
	return msg
}

// IsNotFound reports whether err is an API 404.
func IsNotFound(err error) bool {
	var apiErr *APIError
	return errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound
}

// retryingDoer is the generated client's transport. It sends each request through
// Client.sendRequest, so every generated call gets the same retries and errors.
type retryingDoer struct{ c *Client }

func (d retryingDoer) Do(req *http.Request) (*http.Response, error) { return d.c.sendRequest(req) }

// sendRequest sends req and returns a 2xx response with its body read in full, or an
// error: an *APIError for any other status, or the transport's error wrapped with the
// method and path. Neither the body nor any part of it but the API's error code ever
// reaches an error.
//
// Onidel answers bursts (a parallel Pulumi refresh) with 503. Idempotent requests
// (GET, PUT, DELETE) retry on 429, 502, 503 and 504 with exponential backoff; a POST
// or PATCH never retries, so it cannot run twice.
func (c *Client) sendRequest(req *http.Request) (*http.Response, error) {
	for attempt := 0; ; attempt++ {
		resp, err := c.sendOnce(req)
		if !shouldRetry(req.Method, err) || attempt >= maxRetries {
			return resp, err
		}
		if err := c.Sleep(req.Context(), c.RetryBase<<attempt); err != nil {
			return nil, err
		}
		if req, err = buildRetry(req); err != nil {
			return nil, err
		}
	}
}

const maxRetries = 4

func shouldRetry(method string, err error) bool {
	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		return false
	}
	switch method {
	case http.MethodGet, http.MethodPut, http.MethodDelete:
	default:
		return false
	}
	switch apiErr.Status {
	case http.StatusTooManyRequests, http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		return true
	}
	return false
}

// buildRetry copies req with a fresh body. The generated client builds every body from
// bytes, so net/http gives each request a GetBody.
func buildRetry(req *http.Request) (*http.Request, error) {
	retry := req.Clone(req.Context())
	if req.GetBody != nil {
		body, err := req.GetBody()
		if err != nil {
			return nil, err
		}
		retry.Body = body
	}
	return retry, nil
}

func (c *Client) sendOnce(req *http.Request) (*http.Response, error) {
	path := req.URL.EscapedPath()
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("onidel: %s %s: %w", req.Method, path, err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return nil, fmt.Errorf("onidel: %s %s: read body: %w", req.Method, path, err)
	}

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, &APIError{
			Method: req.Method,
			Path:   path,
			Status: resp.StatusCode,
			Code:   parseErrorCode(raw),
		}
	}
	resp.Body = io.NopCloser(bytes.NewReader(raw))
	return resp, nil
}

// parseErrorCode pulls the short error code out of an error body. Onidel documents
// `{"err": "CODE"}`; `error` and `message` are accepted too. Anything else in the body
// is dropped.
func parseErrorCode(raw []byte) string {
	var body struct {
		Err     any `json:"err"`
		Error   any `json:"error"`
		Message any `json:"message"`
	}
	if json.Unmarshal(raw, &body) != nil {
		return ""
	}
	for _, v := range []any{body.Err, body.Error, body.Message} {
		if s, ok := v.(string); ok && s != "" {
			if len(s) > maxErrorDetail {
				s = s[:maxErrorDetail]
			}
			return s
		}
	}
	return ""
}

// readBody returns the body of a response that sendRequest already read in full, or
// err. Only callers in this package that must sniff an undocumented body use the bytes;
// they are never logged or put into an error.
func readBody(resp *http.Response, err error) ([]byte, error) {
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	return io.ReadAll(resp.Body)
}

// decodeResponse decodes a generated call's response into a T. An empty body decodes
// as T's zero value.
func decodeResponse[T any](resp *http.Response, err error) (T, error) {
	var out T
	raw, err := readBody(resp, err)
	if err != nil || len(bytes.TrimSpace(raw)) == 0 {
		return out, err
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		// The decode error names a type and offset, not body content.
		return out, fmt.Errorf("onidel: decode %s %s: %w", resp.Request.Method, resp.Request.URL.EscapedPath(), err)
	}
	return out, nil
}

// requireSuccess returns err from a generated call whose body the caller does not need.
func requireSuccess(resp *http.Response, err error) error {
	_, err = readBody(resp, err)
	return err
}

// buildTeamID returns teamID as the generated query parameter, nil when empty so the
// request leaves it out and the API uses the default team.
func buildTeamID(teamID string) *string {
	if teamID == "" {
		return nil
	}
	return &teamID
}

// waitFor polls check until it reports done, returns an error, or ctx ends. check
// gets the wait's own context, so its requests and their retries end at timeout too.
// It also gives up once its sleeps add up to timeout: a real sleep lasts at least as
// long as asked, so that never comes before the context's own deadline, and it lets
// an injected Sleep reach the timeout without the wall clock.
func (c *Client) waitFor(
	ctx context.Context, timeout time.Duration, check func(ctx context.Context) (bool, error),
) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var slept time.Duration
	for {
		done, err := check(ctx)
		if err != nil || done {
			return err
		}
		if slept >= timeout {
			return context.DeadlineExceeded
		}
		if err := c.Sleep(ctx, c.PollInterval); err != nil {
			return err
		}
		slept += c.PollInterval
	}
}
