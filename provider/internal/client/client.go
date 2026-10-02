// Package client is a small typed HTTP client for the parts of the Onidel cloud API
// that the provider uses. It is written against provider/spec/onidel.yaml.
//
// Security: the API returns a VM's root password in plain text. No type in this
// package has a field for it, so it is dropped at decode time, and no function here
// logs or formats a response body.
package client

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// DefaultBaseURL is the production Onidel API.
const DefaultBaseURL = "https://api.cloud.onidel.com"

const (
	maxResponseBytes = 4 << 20
	maxErrorDetail   = 200
)

// DefaultPollInterval is the PollInterval New gives a client.
var DefaultPollInterval = 10 * time.Second

// Client talks to the Onidel API with a bearer token.
type Client struct {
	baseURL string
	apiKey  string
	http    *http.Client
	// PollInterval is how long the wait helpers sleep between reads.
	PollInterval time.Duration
	// RetryBase is the first backoff for a retried request; it doubles per retry.
	RetryBase time.Duration
}

// New returns a client for baseURL (DefaultBaseURL when empty).
func New(baseURL, apiKey string) *Client {
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	return &Client{
		baseURL:      strings.TrimRight(baseURL, "/"),
		apiKey:       apiKey,
		http:         &http.Client{Timeout: 60 * time.Second},
		PollInterval: DefaultPollInterval,
		RetryBase:    500 * time.Millisecond,
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

// sendRequest sends one request. body, when non-nil, is encoded as JSON; out, when
// non-nil, receives the decoded response. The raw response bytes are returned only
// for callers in this package that must sniff an undocumented body; they are never
// logged or put into an error.
//
// Onidel answers bursts (a parallel Pulumi refresh) with 503. Idempotent requests
// (GET, PUT, DELETE) retry on 429, 502, 503 and 504 with exponential backoff; a POST
// or PATCH never retries, so it cannot run twice.
func (c *Client) sendRequest(
	ctx context.Context, method, path string, query url.Values, body, out any,
) ([]byte, error) {
	for attempt := 0; ; attempt++ {
		raw, err := c.sendOnce(ctx, method, path, query, body, out)
		if !shouldRetry(method, err) || attempt >= maxRetries {
			return raw, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(c.RetryBase << attempt):
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

func (c *Client) sendOnce(
	ctx context.Context, method, path string, query url.Values, body, out any,
) ([]byte, error) {
	target := c.baseURL + path
	if len(query) > 0 {
		target += "?" + query.Encode()
	}

	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("onidel: encode %s %s: %w", method, path, err)
		}
		reader = bytes.NewReader(encoded)
	}

	req, err := http.NewRequestWithContext(ctx, method, target, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("onidel: %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return nil, fmt.Errorf("onidel: %s %s: read body: %w", method, path, err)
	}

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, &APIError{
			Method: method,
			Path:   path,
			Status: resp.StatusCode,
			Code:   parseErrorCode(raw),
		}
	}

	if out != nil && len(bytes.TrimSpace(raw)) > 0 {
		if err := json.Unmarshal(raw, out); err != nil {
			// The decode error names a type and offset, not body content.
			return nil, fmt.Errorf("onidel: decode %s %s: %w", method, path, err)
		}
	}
	return raw, nil
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

// buildTeamQuery returns the team_id query, or nil when teamID is empty.
func buildTeamQuery(teamID string) url.Values {
	if teamID == "" {
		return nil
	}
	return url.Values{"team_id": {teamID}}
}

// waitFor polls check until it reports done, returns an error, or ctx ends.
func (c *Client) waitFor(ctx context.Context, timeout time.Duration, check func() (bool, error)) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	for {
		done, err := check()
		if err != nil || done {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(c.PollInterval):
		}
	}
}
