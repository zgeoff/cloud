package onidel

import (
	"encoding/json"
	"maps"
	"slices"
	"testing"
	"time"

	"github.com/blang/semver"
	p "github.com/pulumi/pulumi-go-provider"
	"github.com/pulumi/pulumi-go-provider/integration"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

// setupTest starts the fake API and a provider configured against it. Go allows one
// setupTest per package, so this one serves every test file in the package.
func setupTest(t *testing.T) struct {
	api    *onideltest.FakeAPI
	server integration.Server
} {
	t.Helper()
	previous := client.DefaultPollInterval
	// The VM wait helpers sleep on the wall clock; keep each sleep short.
	client.DefaultPollInterval = time.Millisecond
	t.Cleanup(func() { client.DefaultPollInterval = previous })
	api := onideltest.StartFakeAPI(t)
	t.Cleanup(func() { assert.Empty(t, api.GetProblems(), "the fake API saw requests it does not serve") })

	prov, err := New()
	require.NoError(t, err)
	server, err := integration.NewServer(t.Context(), Name, semver.MustParse("0.1.0"), integration.WithProvider(prov))
	require.NoError(t, err)
	// Boot data: every resource call needs a configured API client.
	require.NoError(t, server.Configure(p.ConfigureRequest{Args: onideltest.BuildProps(map[string]any{
		"apiKey": onideltest.APIKey, "endpoint": api.URL,
	})}))
	return struct {
		api    *onideltest.FakeAPI
		server integration.Server
	}{api: api, server: server}
}

func TestSchemaPublishesEveryResourceToken(t *testing.T) {
	ctx := setupTest(t)

	resp, err := ctx.server.GetSchema(p.GetSchemaRequest{})

	require.NoError(t, err)
	var schema struct {
		Resources map[string]json.RawMessage `json:"resources"`
	}
	require.NoError(t, json.Unmarshal([]byte(resp.Schema), &schema))
	assert.Equal(t, []string{
		"onidel:index:FirewallGroup", "onidel:index:FirewallRule", "onidel:index:Rdns", "onidel:index:SshKey", "onidel:index:Vm",
	}, slices.Sorted(maps.Keys(schema.Resources)))
}

func TestSchemaNamesTheNodeSDKPackage(t *testing.T) {
	ctx := setupTest(t)

	resp, err := ctx.server.GetSchema(p.GetSchemaRequest{})

	require.NoError(t, err)
	var schema struct {
		Language struct {
			Nodejs struct {
				PackageName string `json:"packageName"`
			} `json:"nodejs"`
		} `json:"language"`
	}
	require.NoError(t, json.Unmarshal([]byte(resp.Schema), &schema))
	assert.Equal(t, "@zgeoff/pulumi-onidel", schema.Language.Nodejs.PackageName)
}

func TestSchemaGivesTheVmNoPasswordProperty(t *testing.T) {
	ctx := setupTest(t)

	resp, err := ctx.server.GetSchema(p.GetSchemaRequest{})

	require.NoError(t, err)
	var schema struct {
		Resources map[string]struct {
			Properties map[string]json.RawMessage `json:"properties"`
		} `json:"resources"`
	}
	require.NoError(t, json.Unmarshal([]byte(resp.Schema), &schema))
	assert.Equal(t, []string{
		"bgpEnabled", "cpu", "createdAt", "disableSshBlocking", "disk", "firewallGroupId", "instanceType", "ipv6", "isoId",
		"location", "mainIpv4", "mainIpv6", "name", "os", "paymentCycle", "ram", "snapshotId", "sshKeys", "startupScriptId",
		"status", "template", "vpcs",
	}, slices.Sorted(maps.Keys(schema.Resources["onidel:index:Vm"].Properties)))
}

func TestSchemaNeverNamesAPassword(t *testing.T) {
	ctx := setupTest(t)

	resp, err := ctx.server.GetSchema(p.GetSchemaRequest{})

	require.NoError(t, err)
	require.Contains(t, resp.Schema, `"onidel:index:Vm"`)
	assert.NotContains(t, resp.Schema, `"password"`)
}
