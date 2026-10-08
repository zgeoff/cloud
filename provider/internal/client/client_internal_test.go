package client

import (
	"encoding/json"
	"reflect"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

// setupTest starts the stub API and a client for it. These tests sit inside the
// package because no exported method sends a body that json.Marshal rejects.
func setupTest(t *testing.T) struct {
	api    *onideltest.StubOnidelAPI
	client *Client
} {
	t.Helper()
	api := onideltest.StartStubOnidelAPI(t)
	return struct {
		api    *onideltest.StubOnidelAPI
		client *Client
	}{api: api, client: New(api.URL, onideltest.APIKey)}
}

func TestSendRequestFailsBeforeSendingABodyThatDoesNotEncode(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.client.sendRequest(t.Context(), "POST", "/vm", nil, map[string]any{"name": make(chan int)}, nil)

	var typeErr *json.UnsupportedTypeError
	require.ErrorAs(t, err, &typeErr)
	assert.Equal(t, &json.UnsupportedTypeError{Type: reflect.TypeFor[chan int]()}, typeErr)
	assert.EqualError(t, err, "onidel: encode POST /vm: json: unsupported type: chan int")
	assert.Equal(t, []onideltest.Request(nil), ctx.api.GetRequests())
}
