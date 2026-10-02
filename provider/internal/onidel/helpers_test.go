package onidel

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/blang/semver"
	p "github.com/pulumi/pulumi-go-provider"
	"github.com/pulumi/pulumi-go-provider/integration"
	presource "github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/pulumi/pulumi/sdk/v3/go/property"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
)

// setupTestServer starts a fake API and a configured provider pointed at it.
func setupTestServer(t *testing.T) (integration.Server, *fakeAPI) {
	t.Helper()
	client.DefaultPollInterval = time.Millisecond
	api, httpServer := newFakeAPI(t)

	prov, err := New()
	require.NoError(t, err)
	server, err := integration.NewServer(t.Context(), Name, semver.MustParse("0.1.0"), integration.WithProvider(prov))
	require.NoError(t, err)
	require.NoError(t, server.Configure(p.ConfigureRequest{Args: buildProps(map[string]any{
		"apiKey":   "test-key",
		"endpoint": httpServer.URL,
	})}))
	return server, api
}

func buildURN(token, name string) presource.URN {
	return presource.URN("urn:pulumi:test::test::" + token + "::" + name)
}

// buildProps turns a plain Go map into a property map. Numbers must be float64 or int.
func buildProps(m map[string]any) property.Map {
	pm := presource.NewPropertyMapFromMap(m)
	return presource.FromResourcePropertyValue(presource.NewObjectProperty(pm)).AsMap()
}

// toPlain flattens a property map for assertions.
func toPlain(m property.Map) map[string]any {
	return presource.ToResourcePropertyValue(property.New(m)).ObjectValue().Mappable()
}

// encodeProps renders a property map to JSON, to search it for leaked values.
func encodeProps(t *testing.T, m property.Map) string {
	t.Helper()
	raw, err := json.Marshal(toPlain(m))
	require.NoError(t, err)
	return string(raw)
}
