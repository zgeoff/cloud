// Package onideltest holds the shared test utilities for the Onidel provider: an
// in-memory stand-in for the Onidel API and the helpers that build Pulumi property
// values. It must not import the client package, whose own tests use it.
package onideltest

// Request is one request the stub API received, in arrival order.
type Request struct {
	Method string
	Path   string
	// Query is the raw query string, such as "team_id=…".
	Query string
	// Body is the decoded JSON body, or nil when the request had none.
	Body map[string]any
}
