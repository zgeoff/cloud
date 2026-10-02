package onidel

import (
	"testing"

	p "github.com/pulumi/pulumi-go-provider"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSchema(t *testing.T) {
	server, _ := setupTestServer(t)
	resp, err := server.GetSchema(p.GetSchemaRequest{})
	require.NoError(t, err)
	for _, token := range []string{
		"onidel:index:SshKey", "onidel:index:Vm", "onidel:index:FirewallGroup",
		"onidel:index:FirewallRule", "onidel:index:Rdns",
	} {
		assert.Contains(t, resp.Schema, `"`+token+`"`)
	}
	assert.Contains(t, resp.Schema, `"packageName":"`+NodePackageName+`"`)
	assert.NotContains(t, resp.Schema, `"password"`)
}

func TestConfigureFallsBackToEnv(t *testing.T) {
	t.Setenv(APIKeyEnv, "")
	cfg := &Config{}
	require.ErrorContains(t, cfg.Configure(t.Context()), APIKeyEnv)

	t.Setenv(APIKeyEnv, "from-env")
	cfg = &Config{}
	require.NoError(t, cfg.Configure(t.Context()))
	assert.Equal(t, "from-env", cfg.APIKey)
}

func TestSSHKeyLifecycle(t *testing.T) {
	server, api := setupTestServer(t)
	urn := buildURN("onidel:index:SshKey", "me")
	inputs := map[string]any{"name": "me", "publicKey": "ssh-ed25519 AAAAC3Nza me@host\n"}

	created, err := server.Create(p.CreateRequest{Urn: urn, Properties: buildProps(inputs)})
	require.NoError(t, err)
	require.NotEmpty(t, created.ID)
	assert.Equal(t, fakeTeamID, api.collectRequests("POST")[0].Body["team_id"], "team resolved from /teams")

	read, err := server.Read(p.ReadRequest{ID: created.ID, Urn: urn, Properties: created.Properties, Inputs: buildProps(inputs)})
	require.NoError(t, err)
	assert.Equal(t, inputs["publicKey"], toPlain(read.Inputs)["publicKey"])

	next := map[string]any{"name": "me-2", "publicKey": "ssh-ed25519 AAAAC3Nzb me@host"}
	diff, err := server.Diff(p.DiffRequest{ID: created.ID, Urn: urn, State: read.Properties, OldInputs: read.Inputs, Inputs: buildProps(next)})
	require.NoError(t, err)
	assert.Equal(t, p.Update, diff.DetailedDiff["name"].Kind)
	assert.Equal(t, p.Update, diff.DetailedDiff["publicKey"].Kind)

	_, err = server.Update(p.UpdateRequest{ID: created.ID, Urn: urn, State: read.Properties, OldInputs: read.Inputs, Inputs: buildProps(next)})
	require.NoError(t, err)
	patch := api.collectRequests("PATCH")[0]
	assert.Equal(t, map[string]any{"team_id": fakeTeamID, "name": "me-2", "ssh_key": "ssh-ed25519 AAAAC3Nzb me@host"}, patch.Body)

	require.NoError(t, server.Delete(p.DeleteRequest{ID: created.ID, Urn: urn, Properties: created.Properties}))
	assert.Empty(t, api.sshKeys)
	gone, err := server.Read(p.ReadRequest{ID: created.ID, Urn: urn})
	require.NoError(t, err)
	assert.Empty(t, gone.ID)
}

func TestFirewallGroupLifecycle(t *testing.T) {
	server, api := setupTestServer(t)
	urn := buildURN("onidel:index:FirewallGroup", "fw")

	created, err := server.Create(p.CreateRequest{Urn: urn, Properties: buildProps(map[string]any{"description": "cloud"})})
	require.NoError(t, err)
	assert.EqualValues(t, 0, toPlain(created.Properties)["ruleCount"])

	read, err := server.Read(p.ReadRequest{ID: created.ID, Urn: urn})
	require.NoError(t, err)
	assert.Equal(t, "cloud", toPlain(read.Inputs)["description"])

	next := buildProps(map[string]any{"description": "cloud host"})
	diff, err := server.Diff(p.DiffRequest{ID: created.ID, Urn: urn, State: read.Properties, OldInputs: read.Inputs, Inputs: next})
	require.NoError(t, err)
	assert.Equal(t, p.Update, diff.DetailedDiff["description"].Kind)

	updated, err := server.Update(p.UpdateRequest{ID: created.ID, Urn: urn, State: read.Properties, OldInputs: read.Inputs, Inputs: next})
	require.NoError(t, err)
	assert.Equal(t, "cloud host", toPlain(updated.Properties)["description"])
	assert.Equal(t, "PUT", api.collectRequests("PUT")[0].Method)

	require.NoError(t, server.Delete(p.DeleteRequest{ID: created.ID, Urn: urn, Properties: created.Properties}))
	assert.Empty(t, api.firewalls)
}

func TestFirewallRuleLifecycle(t *testing.T) {
	server, api := setupTestServer(t)
	group, err := server.Create(p.CreateRequest{
		Urn: buildURN("onidel:index:FirewallGroup", "fw"), Properties: buildProps(map[string]any{"description": "cloud"}),
	})
	require.NoError(t, err)

	urn := buildURN("onidel:index:FirewallRule", "icmp6")
	inputs := map[string]any{"firewallId": group.ID, "protocol": "icmp", "subnet": "::", "subnetSize": 0}
	created, err := server.Create(p.CreateRequest{Urn: urn, Properties: buildProps(inputs)})
	require.NoError(t, err)
	assert.Equal(t, group.ID+"/", created.ID[:len(group.ID)+1])

	// The API stores icmp on a v6 subnet as ipv6-icmp; that must not read as drift.
	read, err := server.Read(p.ReadRequest{ID: created.ID, Urn: urn, Properties: created.Properties, Inputs: buildProps(inputs)})
	require.NoError(t, err)
	diff, err := server.Diff(p.DiffRequest{ID: created.ID, Urn: urn, State: read.Properties, OldInputs: read.Inputs, Inputs: buildProps(inputs)})
	require.NoError(t, err)
	assert.False(t, diff.HasChanges, "%v", diff.DetailedDiff)

	// Import by composite ID.
	imported, err := server.Read(p.ReadRequest{ID: created.ID, Urn: urn})
	require.NoError(t, err)
	assert.Equal(t, "ipv6-icmp", toPlain(imported.Inputs)["protocol"])
	assert.Equal(t, group.ID, toPlain(imported.Inputs)["firewallId"])

	// Description updates in place; port replaces.
	withDesc := map[string]any{"firewallId": group.ID, "protocol": "icmp", "subnet": "::", "subnetSize": 0, "description": "ping"}
	diff, err = server.Diff(p.DiffRequest{ID: created.ID, Urn: urn, State: read.Properties, OldInputs: read.Inputs, Inputs: buildProps(withDesc)})
	require.NoError(t, err)
	assert.Equal(t, p.Add, diff.DetailedDiff["description"].Kind)
	_, err = server.Update(p.UpdateRequest{ID: created.ID, Urn: urn, State: read.Properties, OldInputs: read.Inputs, Inputs: buildProps(withDesc)})
	require.NoError(t, err)
	assert.Equal(t, "ping", api.collectRequests("PATCH")[0].Body["desc"])

	withPort := map[string]any{"firewallId": group.ID, "protocol": "tcp", "port": "443", "subnet": "0.0.0.0", "subnetSize": 0}
	diff, err = server.Diff(p.DiffRequest{ID: created.ID, Urn: urn, State: read.Properties, OldInputs: read.Inputs, Inputs: buildProps(withPort)})
	require.NoError(t, err)
	assert.Equal(t, p.AddReplace, diff.DetailedDiff["port"].Kind)
	assert.Equal(t, p.UpdateReplace, diff.DetailedDiff["protocol"].Kind)

	require.NoError(t, server.Delete(p.DeleteRequest{ID: created.ID, Urn: urn, Properties: created.Properties}))
	assert.Empty(t, api.rules)

	_, err = server.Read(p.ReadRequest{ID: "no-slash", Urn: urn})
	require.ErrorContains(t, err, "<firewallId>/<ruleId>")
}

func TestRDNSLifecycle(t *testing.T) {
	server, api := setupTestServer(t)
	const vmID = "0f289413-258f-4115-ac81-252000998fe0"
	api.vms[vmID] = liveShapedVM(vmID)
	urn := buildURN("onidel:index:Rdns", "v4")
	inputs := map[string]any{"vmId": vmID, "ip": "203.0.113.18", "domain": "geoff.cloud"}

	created, err := server.Create(p.CreateRequest{Urn: urn, Properties: buildProps(inputs)})
	require.NoError(t, err)
	assert.Equal(t, vmID+"/203.0.113.18", created.ID)
	assert.Equal(t, "geoff.cloud", api.rdns[vmID]["203.0.113.18"])

	imported, err := server.Read(p.ReadRequest{ID: created.ID, Urn: urn})
	require.NoError(t, err)
	assert.Equal(t, inputs, toPlain(imported.Inputs))

	next := map[string]any{"vmId": vmID, "ip": "203.0.113.18", "domain": "host.geoff.cloud"}
	diff, err := server.Diff(p.DiffRequest{ID: created.ID, Urn: urn, State: imported.Properties, OldInputs: imported.Inputs, Inputs: buildProps(next)})
	require.NoError(t, err)
	assert.Equal(t, p.Update, diff.DetailedDiff["domain"].Kind)
	_, err = server.Update(p.UpdateRequest{ID: created.ID, Urn: urn, State: imported.Properties, OldInputs: imported.Inputs, Inputs: buildProps(next)})
	require.NoError(t, err)
	assert.Equal(t, "host.geoff.cloud", api.rdns[vmID]["203.0.113.18"])

	moved := map[string]any{"vmId": vmID, "ip": "2001:db8:4:17f::", "domain": "host.geoff.cloud"}
	diff, err = server.Diff(p.DiffRequest{ID: created.ID, Urn: urn, State: imported.Properties, OldInputs: imported.Inputs, Inputs: buildProps(moved)})
	require.NoError(t, err)
	assert.Equal(t, p.UpdateReplace, diff.DetailedDiff["ip"].Kind)

	require.NoError(t, server.Delete(p.DeleteRequest{ID: created.ID, Urn: urn, Properties: created.Properties}))
	assert.Empty(t, api.rdns[vmID])
	gone, err := server.Read(p.ReadRequest{ID: created.ID, Urn: urn})
	require.NoError(t, err)
	assert.Empty(t, gone.ID)
}
