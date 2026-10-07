package onideltest_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

// These tests pin each assumption the stub makes about the real API, on the wire,
// against provider/spec/onidel.yaml. They drive raw HTTP so that no client decoding
// stands between the test and the stub's output.

// setupTest starts a stub API.
func setupTest(t *testing.T) struct {
	api *onideltest.StubOnidelAPI
} {
	t.Helper()
	return struct {
		api *onideltest.StubOnidelAPI
	}{api: onideltest.StartStubOnidelAPI(t)}
}

func TestStubOnidelAPIListsItsOneTeamAsABareArray(t *testing.T) {
	ctx := setupTest(t)

	status, body := onideltest.SendRequest(t, ctx.api.URL, "GET", "/teams", "")

	assert.Equal(t, http.StatusOK, status)
	assert.JSONEq(t, `[{"id":"169b0175-361a-4ea7-b31f-d82f42bc43b1","name":"team","role":"Team Owner"}]`, body)
}

func TestStubOnidelAPIListsTheTeamsATestSets(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(
		map[string]any{"id": "team-a", "name": "a", "role": "Team Owner"},
		map[string]any{"id": "team-b", "name": "b", "role": "Team Member"},
	)

	_, body := onideltest.SendRequest(t, ctx.api.URL, "GET", "/teams", "")

	assert.JSONEq(t, `[{"id":"team-a","name":"a","role":"Team Owner"},{"id":"team-b","name":"b","role":"Team Member"}]`, body)
}

func TestStubOnidelAPIListsOSTemplatesAsABareArray(t *testing.T) {
	ctx := setupTest(t)

	_, body := onideltest.SendRequest(t, ctx.api.URL, "GET", "/os_templates", "")

	assert.JSONEq(t, `[{"id":3,"name":"Ubuntu 24.04 LTS x64","family":"Ubuntu"},`+
		`{"id":24,"name":"Ubuntu 26.04 LTS x64","family":"Ubuntu"}]`, body)
}

func TestStubOnidelAPIRejectsAWrongBearerToken(t *testing.T) {
	ctx := setupTest(t)
	req, err := http.NewRequestWithContext(t.Context(), "GET", ctx.api.URL+"/teams", nil)
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer other-key")

	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	t.Cleanup(func() { _ = resp.Body.Close() })

	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode)
}

func TestStubOnidelAPIReportsARequestNoRouteServes(t *testing.T) {
	rows := []struct {
		name    string
		method  string
		path    string
		problem string
	}{
		{"it reports an unknown path with its query", "GET", "/nope?team_id=x", "unhandled request: GET /nope?team_id=x"},
		{"it reports an unknown method on a known path", "OPTIONS", "/vm", "unhandled request: OPTIONS /vm"},
		{"it reports an endpoint the stub does not model", "GET", "/ssh_keys", "unhandled request: GET /ssh_keys"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)

			status, _ := onideltest.SendRequest(t, ctx.api.URL, row.method, row.path, "")

			assert.Equal(t, []any{http.StatusInternalServerError, []string{row.problem}}, []any{status, ctx.api.DrainProblems()})
		})
	}
}

func TestStubOnidelAPIReportsABodyThatIsNotAJSONObject(t *testing.T) {
	ctx := setupTest(t)

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "POST", "/ssh_keys", `not json`)

	assert.Equal(t, []any{http.StatusBadRequest, []string{"body is not a JSON object: POST /ssh_keys"}},
		[]any{status, ctx.api.DrainProblems()})
}

func TestStubOnidelAPIRecordsEachRequestWithItsQueryAndBody(t *testing.T) {
	ctx := setupTest(t)

	onideltest.SendRequest(t, ctx.api.URL, "GET", "/vm?team_id=team-a", "")
	onideltest.SendRequest(t, ctx.api.URL, "POST", "/network/firewalls", `{"team_id":"team-a","description":"edge"}`)

	assert.Equal(t, []onideltest.Request{
		{Method: "GET", Path: "/vm", Query: "team_id=team-a"},
		{Method: "POST", Path: "/network/firewalls", Body: map[string]any{"team_id": "team-a", "description": "edge"}},
	}, ctx.api.GetRequests())
}

func TestStubOnidelAPIServesARegisteredHandlerInPlaceOfItsRoute(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterHandler("GET /teams", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	})

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "GET", "/teams", "")

	assert.Equal(t, []any{http.StatusServiceUnavailable, []onideltest.Request{{Method: "GET", Path: "/teams"}}},
		[]any{status, ctx.api.GetRequests()})
}

func TestStubOnidelAPICreatesAnSSHKeyInAnEnvelope(t *testing.T) {
	ctx := setupTest(t)

	status, body := onideltest.SendRequest(t, ctx.api.URL, "POST", "/ssh_keys", `{"team_id":"t","name":"me","ssh_key":"ssh-ed25519 AAAA me@host"}`)

	assert.Equal(t, http.StatusCreated, status)
	assert.JSONEq(t, `{"ssh_key":{"id":"00000000-0000-4000-8000-000000000001","created":"2026-10-02T05:35:28Z",`+
		`"name":"me","ssh_key":"ssh-ed25519 AAAA me@host"}}`, body)
}

func TestStubOnidelAPIRejectsAnSSHKeyWriteMissingARequiredField(t *testing.T) {
	rows := []struct {
		name   string
		method string
		path   string
		body   string
	}{
		{"it rejects a create without team_id", "POST", "/ssh_keys", `{"name":"me","ssh_key":"k"}`},
		{"it rejects a create without name", "POST", "/ssh_keys", `{"team_id":"t","ssh_key":"k"}`},
		{"it rejects a create without ssh_key", "POST", "/ssh_keys", `{"team_id":"t","name":"me"}`},
		{"it rejects an update without team_id", "PATCH", "/ssh_keys/00000000-0000-4000-8000-000000000001", `{"name":"me","ssh_key":"k"}`},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			onideltest.SendRequest(t, ctx.api.URL, "POST", "/ssh_keys", `{"team_id":"t","name":"me","ssh_key":"k"}`)

			status, body := onideltest.SendRequest(t, ctx.api.URL, row.method, row.path, row.body)

			assert.Equal(t, []any{http.StatusBadRequest, ""}, []any{status, body})
		})
	}
}

func TestStubOnidelAPIUpdatesAnSSHKeyNameAndPublicKey(t *testing.T) {
	ctx := setupTest(t)
	onideltest.SendRequest(t, ctx.api.URL, "POST", "/ssh_keys", `{"team_id":"t","name":"me","ssh_key":"k1"}`)

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "PATCH", "/ssh_keys/00000000-0000-4000-8000-000000000001", `{"team_id":"t","name":"me-2","ssh_key":"k2"}`)

	assert.Equal(t, []any{http.StatusNoContent, map[string]map[string]any{
		"00000000-0000-4000-8000-000000000001": {
			"id": "00000000-0000-4000-8000-000000000001", "created": "2026-10-02T05:35:28Z", "name": "me-2", "ssh_key": "k2",
		},
	}}, []any{status, ctx.api.GetSSHKeys()})
}

func TestStubOnidelAPIRemovesAnSSHKey(t *testing.T) {
	ctx := setupTest(t)
	onideltest.SendRequest(t, ctx.api.URL, "POST", "/ssh_keys", `{"team_id":"t","name":"me","ssh_key":"k1"}`)

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "DELETE", "/ssh_keys/00000000-0000-4000-8000-000000000001?team_id=t", "")

	assert.Equal(t, []any{http.StatusNoContent, map[string]map[string]any{}}, []any{status, ctx.api.GetSSHKeys()})
}

func TestStubOnidelAPIAnswersAMissingResourceWithABare404(t *testing.T) {
	rows := []struct {
		name   string
		method string
		path   string
		body   string
	}{
		{"it answers a read of an unknown SSH key", "GET", "/ssh_keys/x", ""},
		{"it answers an update of an unknown SSH key", "PATCH", "/ssh_keys/x", `{"team_id":"t","name":"me","ssh_key":"k"}`},
		{"it answers a removal of an unknown SSH key", "DELETE", "/ssh_keys/x", ""},
		{"it answers a read of an unknown VM", "GET", "/vm/x", ""},
		{"it answers an update of an unknown VM", "PATCH", "/vm/x", `{"name":"web"}`},
		{"it answers a removal of an unknown VM", "DELETE", "/vm/x", ""},
		{"it answers a read of an unknown firewall group", "GET", "/network/firewalls/x", ""},
		{"it answers an update of an unknown firewall group", "PUT", "/network/firewalls/x", `{"description":"d"}`},
		{"it answers a removal of an unknown firewall group", "DELETE", "/network/firewalls/x", ""},
		{"it answers a rule create in an unknown firewall group", "POST", "/network/firewalls/x/rules", `{"protocol":"tcp","subnet":"0.0.0.0","subnet_size":0}`},
		{"it answers a read of an unknown rule", "GET", "/network/firewalls/x/rules/y", ""},
		{"it answers an update of an unknown rule", "PATCH", "/network/firewalls/x/rules/y", `{"desc":"d"}`},
		{"it answers a removal of an unknown rule", "DELETE", "/network/firewalls/x/rules/y", ""},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)

			status, body := onideltest.SendRequest(t, ctx.api.URL, row.method, row.path, row.body)

			assert.Equal(t, []any{http.StatusNotFound, ""}, []any{status, body})
		})
	}
}

func TestStubOnidelAPICreatesABuildingVMWithNoResponseBody(t *testing.T) {
	ctx := setupTest(t)

	status, body := onideltest.SendRequest(t, ctx.api.URL, "POST", "/vm", `{"team_id":"t","name":"web","location":"Sydney","cpu":2,"ram":4096,"disk":40,"os":24,"ipv6":true}`)

	assert.Equal(t, []any{http.StatusCreated, "", map[string]map[string]any{
		"00000000-0000-4000-8000-000000000001": {
			"id": "00000000-0000-4000-8000-000000000001", "name": "web", "vcpu": 2.0, "ram": 4096.0, "disk": 40.0,
			"location": "Sydney", "password": "fixture-root-pw-do-not-leak", "main_ipv4": "203.0.113.10",
			"main_ipv6": "2401:db8::1", "template": "Ubuntu 26.04 LTS x64", "firewall_group_id": nil,
			"created_at": "2026-10-02T05:48:53Z", "status": "building", "active_action_id": nil, "bgp_enabled": false,
		},
	}}, []any{status, body, ctx.api.GetVMs()})
}

func TestStubOnidelAPIRejectsAVMWithoutExactlyOneImageSource(t *testing.T) {
	rows := []struct {
		name string
		body string
	}{
		{"it rejects a VM with no image source", `{"name":"web","location":"Sydney","cpu":2,"ram":4096,"disk":40}`},
		{"it rejects a VM with two image sources", `{"name":"web","location":"Sydney","cpu":2,"ram":4096,"disk":40,"os":24,"iso_id":"i"}`},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)

			status, _ := onideltest.SendRequest(t, ctx.api.URL, "POST", "/vm", row.body)

			assert.Equal(t, []any{http.StatusBadRequest, map[string]map[string]any{}}, []any{status, ctx.api.GetVMs()})
		})
	}
}

func TestStubOnidelAPIListsVMsInTheOrderTheyWereStored(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "b", "name": "second-id", "status": "active"})
	ctx.api.SetVM(map[string]any{"id": "a", "name": "first-id", "status": "active"})

	_, body := onideltest.SendRequest(t, ctx.api.URL, "GET", "/vm", "")

	assert.JSONEq(t, `[{"id":"b","name":"second-id","status":"active"},{"id":"a","name":"first-id","status":"active"}]`, body)
}

func TestStubOnidelAPISettlesABuildingVMAfterOneRead(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "status": "building", "active_action_id": nil})

	_, first := onideltest.SendRequest(t, ctx.api.URL, "GET", "/vm/v", "")
	_, second := onideltest.SendRequest(t, ctx.api.URL, "GET", "/vm/v", "")

	assert.Equal(t, []string{
		`{"active_action_id":null,"id":"v","status":"building"}` + "\n",
		`{"active_action_id":null,"id":"v","status":"active"}` + "\n",
	}, []string{first, second})
}

func TestStubOnidelAPIHoldsABuildingVMWhileAutoSettleIsOff(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "status": "building", "active_action_id": nil})
	ctx.api.SetAutoSettle(false)

	onideltest.SendRequest(t, ctx.api.URL, "GET", "/vm/v", "")
	_, second := onideltest.SendRequest(t, ctx.api.URL, "GET", "/vm/v", "")

	assert.JSONEq(t, `{"active_action_id":null,"id":"v","status":"building"}`, second)
}

func TestStubOnidelAPIStartsAnActionOnAVMUpdate(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "status": "active", "active_action_id": nil})

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "PATCH", "/vm/v", `{"team_id":"t","name":"web-2"}`)

	assert.Equal(t, []any{http.StatusAccepted, map[string]map[string]any{
		"v": {"id": "v", "name": "web-2", "status": "active", "active_action_id": 42},
	}}, []any{status, ctx.api.GetVMs()})
}

func TestStubOnidelAPIRefusesAVMUpdateWhileAnActionRuns(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "status": "active", "active_action_id": 7})

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "PATCH", "/vm/v", `{"name":"web-2"}`)

	assert.Equal(t, http.StatusConflict, status)
}

func TestStubOnidelAPIRejectsAVMUpdateWithoutExactlyOneSetting(t *testing.T) {
	rows := []struct {
		name string
		body string
	}{
		{"it rejects an update with only a team", `{"team_id":"t"}`},
		{"it rejects an update with two settings", `{"name":"web-2","enable_ipv6":true}`},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "status": "active", "active_action_id": nil})

			status, _ := onideltest.SendRequest(t, ctx.api.URL, "PATCH", "/vm/v", row.body)

			assert.Equal(t, http.StatusBadRequest, status)
		})
	}
}

func TestStubOnidelAPIReportsAVMSettingItDoesNotModel(t *testing.T) {
	rows := []struct {
		name    string
		body    string
		problem string
	}{
		{"it reports an OS reinstall", `{"os_id":2}`, "unmodelled VM setting: PATCH /vm/v os_id"},
		{"it reports a boot mode change", `{"use_uefi":true}`, "unmodelled VM setting: PATCH /vm/v use_uefi"},
		{"it reports an SEV change", `{"enable_sev":true}`, "unmodelled VM setting: PATCH /vm/v enable_sev"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetVM(map[string]any{"id": "v", "name": "web", "status": "active", "active_action_id": nil})

			status, _ := onideltest.SendRequest(t, ctx.api.URL, "PATCH", "/vm/v", row.body)

			assert.Equal(t, []any{http.StatusInternalServerError, []string{row.problem}}, []any{status, ctx.api.DrainProblems()})
		})
	}
}

func TestStubOnidelAPIAppliesEachVMSetting(t *testing.T) {
	rows := []struct {
		name string
		body string
		want map[string]map[string]any
	}{
		{"it enables IPv6", `{"enable_ipv6":true}`, map[string]map[string]any{"v": {
			"id": "v", "main_ipv6": "2401:db8::1", "firewall_group_id": "g1", "active_action_id": 42,
		}}},
		{"it disables IPv6", `{"enable_ipv6":false}`, map[string]map[string]any{"v": {
			"id": "v", "main_ipv6": "", "firewall_group_id": "g1", "active_action_id": 42,
		}}},
		{"it attaches a firewall group", `{"firewall_group_id":"g2"}`, map[string]map[string]any{"v": {
			"id": "v", "main_ipv6": "2401:db8::1", "firewall_group_id": "g2", "active_action_id": 42,
		}}},
		{"it detaches the firewall group", `{"disable_firewall":true}`, map[string]map[string]any{"v": {
			"id": "v", "main_ipv6": "2401:db8::1", "firewall_group_id": nil, "active_action_id": 42,
		}}},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetVM(map[string]any{"id": "v", "main_ipv6": "2401:db8::1", "firewall_group_id": "g1", "active_action_id": nil})

			onideltest.SendRequest(t, ctx.api.URL, "PATCH", "/vm/v", row.body)

			assert.Equal(t, row.want, ctx.api.GetVMs())
		})
	}
}

func TestStubOnidelAPICountsTheVMsAttachedToAFirewallGroup(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "instance_count": 1})
	ctx.api.SetFirewallGroup(map[string]any{"id": "g2", "instance_count": 0})
	ctx.api.SetVM(map[string]any{"id": "v", "firewall_group_id": "g1", "active_action_id": nil})

	onideltest.SendRequest(t, ctx.api.URL, "PATCH", "/vm/v", `{"firewall_group_id":"g2"}`)

	assert.Equal(t, map[string]map[string]any{
		"g1": {"id": "g1", "instance_count": 0},
		"g2": {"id": "g2", "instance_count": 1},
	}, ctx.api.GetFirewallGroups())
}

func TestStubOnidelAPIRemovesAVMAndItsFirewallAttachment(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "instance_count": 1})
	ctx.api.SetVM(map[string]any{"id": "v", "firewall_group_id": "g1"})

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "DELETE", "/vm/v", "")

	assert.Equal(t, []any{
		http.StatusNoContent, map[string]map[string]any{}, map[string]map[string]any{"g1": {"id": "g1", "instance_count": 0}},
	}, []any{status, ctx.api.GetVMs(), ctx.api.GetFirewallGroups()})
}

func TestStubOnidelAPIRefusesAFirewallGroupWithoutATeamAs401(t *testing.T) {
	ctx := setupTest(t)

	status, body := onideltest.SendRequest(t, ctx.api.URL, "POST", "/network/firewalls", `{"description":"edge"}`)

	assert.Equal(t, http.StatusUnauthorized, status)
	assert.JSONEq(t, `{"err":"UNAUTHORIZED"}`, body)
}

func TestStubOnidelAPIRejectsAFirewallGroupWriteWithoutADescription(t *testing.T) {
	rows := []struct {
		name   string
		method string
		path   string
		body   string
	}{
		{"it rejects a create", "POST", "/network/firewalls", `{"team_id":"t"}`},
		{"it rejects an update", "PUT", "/network/firewalls/g1", `{"team_id":"t"}`},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "description": "edge"})

			status, _ := onideltest.SendRequest(t, ctx.api.URL, row.method, row.path, row.body)

			assert.Equal(t, http.StatusBadRequest, status)
		})
	}
}

func TestStubOnidelAPICreatesAFirewallGroupInAnEnvelope(t *testing.T) {
	ctx := setupTest(t)

	status, body := onideltest.SendRequest(t, ctx.api.URL, "POST", "/network/firewalls", `{"team_id":"t","description":"edge"}`)

	assert.Equal(t, http.StatusCreated, status)
	assert.JSONEq(t, `{"firewall_group":{"id":"00000000-0000-4000-8000-000000000001","description":"edge",`+
		`"created":"2026-10-02T00:00:00Z","updated":"2026-10-02T00:00:00Z","instance_count":0,"rule_count":0}}`, body)
}

func TestStubOnidelAPIUpdatesAFirewallGroupDescription(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "description": "edge", "updated": "2026-10-02T00:00:00Z"})

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "PUT", "/network/firewalls/g1", `{"description":"edge 2"}`)

	assert.Equal(t, []any{http.StatusNoContent, map[string]map[string]any{
		"g1": {"id": "g1", "description": "edge 2", "updated": "2026-10-03T00:00:00Z"},
	}}, []any{status, ctx.api.GetFirewallGroups()})
}

func TestStubOnidelAPIRefusesToRemoveAFirewallGroupWithVMsAttached(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "instance_count": 1})

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "DELETE", "/network/firewalls/g1", "")

	assert.Equal(t, []any{http.StatusBadRequest, map[string]map[string]any{"g1": {"id": "g1", "instance_count": 1}}},
		[]any{status, ctx.api.GetFirewallGroups()})
}

func TestStubOnidelAPIRemovesAFirewallGroupWithNoVMs(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "instance_count": 0})

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "DELETE", "/network/firewalls/g1", "")

	assert.Equal(t, []any{http.StatusNoContent, map[string]map[string]any{}}, []any{status, ctx.api.GetFirewallGroups()})
}

func TestStubOnidelAPIStoresARuleUnderItsSubnetFamily(t *testing.T) {
	rows := []struct {
		name string
		body string
		want string
	}{
		{
			"it stores ICMP on a v6 subnet as ipv6-icmp",
			`{"protocol":"icmp","subnet":"::","subnet_size":0}`,
			`{"firewall_rule":{"id":"00000000-0000-4000-8000-000000000001","group":"g1","action":"allow",` +
				`"ip_type":"v6","protocol":"ipv6-icmp","port":"","subnet":"::","subnet_size":"0","desc":""}}`,
		},
		{
			"it stores ipv6-icmp on a v4 subnet as icmp",
			`{"protocol":"ipv6-icmp","subnet":"0.0.0.0","subnet_size":0}`,
			`{"firewall_rule":{"id":"00000000-0000-4000-8000-000000000001","group":"g1","action":"allow",` +
				`"ip_type":"v4","protocol":"icmp","port":"","subnet":"0.0.0.0","subnet_size":"0","desc":""}}`,
		},
		{
			"it stores TCP on a v6 subnet as v6",
			`{"protocol":"tcp","port":"443","subnet":"2001:db8::","subnet_size":32,"desc":"web"}`,
			`{"firewall_rule":{"id":"00000000-0000-4000-8000-000000000001","group":"g1","action":"allow",` +
				`"ip_type":"v6","protocol":"tcp","port":"443","subnet":"2001:db8::","subnet_size":"32","desc":"web"}}`,
		},
		{
			"it stores a special subnet value as v4",
			`{"protocol":"tcp","port":"443","subnet":"Cloudflare","subnet_size":0}`,
			`{"firewall_rule":{"id":"00000000-0000-4000-8000-000000000001","group":"g1","action":"allow",` +
				`"ip_type":"v4","protocol":"tcp","port":"443","subnet":"Cloudflare","subnet_size":"0","desc":""}}`,
		},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})

			status, body := onideltest.SendRequest(t, ctx.api.URL, "POST", "/network/firewalls/g1/rules", row.body)

			assert.Equal(t, http.StatusCreated, status)
			assert.JSONEq(t, row.want, body)
		})
	}
}

func TestStubOnidelAPIRejectsARuleMissingARequiredField(t *testing.T) {
	rows := []struct {
		name string
		body string
	}{
		{"it rejects a rule without a protocol", `{"subnet":"0.0.0.0","subnet_size":0}`},
		{"it rejects a rule with an unknown protocol", `{"protocol":"gre","subnet":"0.0.0.0","subnet_size":0}`},
		{"it rejects a rule without a subnet", `{"protocol":"tcp","subnet_size":0}`},
		{"it rejects a rule without a subnet size", `{"protocol":"tcp","subnet":"0.0.0.0"}`},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})

			status, _ := onideltest.SendRequest(t, ctx.api.URL, "POST", "/network/firewalls/g1/rules", row.body)

			assert.Equal(t, http.StatusBadRequest, status)
		})
	}
}

func TestStubOnidelAPIReadsARuleWithANumericSubnetSize(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})
	onideltest.SendRequest(t, ctx.api.URL, "POST", "/network/firewalls/g1/rules", `{"protocol":"tcp","port":"443","subnet":"0.0.0.0","subnet_size":24}`)

	status, body := onideltest.SendRequest(t, ctx.api.URL, "GET", "/network/firewalls/g1/rules/00000000-0000-4000-8000-000000000001", "")

	assert.Equal(t, http.StatusOK, status)
	assert.JSONEq(t, `{"firewall_rule":{"id":"00000000-0000-4000-8000-000000000001","group":"g1","ip_type":"v4",`+
		`"action":"allow","protocol":"tcp","port":"443","subnet":"0.0.0.0","subnet_size":24,"desc":""}}`, body)
}

func TestStubOnidelAPICountsTheRulesInAFirewallGroup(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})

	onideltest.SendRequest(t, ctx.api.URL, "POST", "/network/firewalls/g1/rules", `{"protocol":"tcp","subnet":"0.0.0.0","subnet_size":0}`)
	onideltest.SendRequest(t, ctx.api.URL, "POST", "/network/firewalls/g1/rules", `{"protocol":"udp","subnet":"0.0.0.0","subnet_size":0}`)
	onideltest.SendRequest(t, ctx.api.URL, "DELETE", "/network/firewalls/g1/rules/00000000-0000-4000-8000-000000000001", "")

	assert.Equal(t, map[string]map[string]any{"g1": {"id": "g1", "rule_count": 1}}, ctx.api.GetFirewallGroups())
}

func TestStubOnidelAPIFindsARuleOnlyInItsOwnGroup(t *testing.T) {
	rows := []struct {
		name   string
		method string
		body   string
	}{
		{"it hides the rule from a read", "GET", ""},
		{"it refuses an update", "PATCH", `{"desc":"d"}`},
		{"it refuses a removal", "DELETE", ""},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})
			ctx.api.SetFirewallGroup(map[string]any{"id": "g2", "rule_count": 0})
			onideltest.SendRequest(t, ctx.api.URL, "POST", "/network/firewalls/g1/rules", `{"protocol":"tcp","subnet":"0.0.0.0","subnet_size":0}`)

			status, _ := onideltest.SendRequest(t, ctx.api.URL, row.method, "/network/firewalls/g2/rules/00000000-0000-4000-8000-000000000001", row.body)

			assert.Equal(t, []any{http.StatusNotFound, map[string]map[string]any{"00000000-0000-4000-8000-000000000001": {
				"id": "00000000-0000-4000-8000-000000000001", "group": "g1", "ip_type": "v4", "action": "allow",
				"protocol": "tcp", "port": "", "subnet": "0.0.0.0", "subnet_size": 0.0, "desc": "",
			}}}, []any{status, ctx.api.GetFirewallRules()})
		})
	}
}

func TestStubOnidelAPIUpdatesARuleDescription(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})
	onideltest.SendRequest(t, ctx.api.URL, "POST", "/network/firewalls/g1/rules", `{"protocol":"tcp","subnet":"0.0.0.0","subnet_size":0}`)

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "PATCH", "/network/firewalls/g1/rules/00000000-0000-4000-8000-000000000001", `{"team_id":"t","desc":"web"}`)

	assert.Equal(t, []any{http.StatusOK, map[string]map[string]any{"00000000-0000-4000-8000-000000000001": {
		"id": "00000000-0000-4000-8000-000000000001", "group": "g1", "ip_type": "v4", "action": "allow",
		"protocol": "tcp", "port": "", "subnet": "0.0.0.0", "subnet_size": 0.0, "desc": "web",
	}}}, []any{status, ctx.api.GetFirewallRules()})
}

func TestStubOnidelAPIRejectsARuleUpdateWithoutAValidDescription(t *testing.T) {
	rows := []struct {
		name string
		body string
	}{
		{"it rejects an update without desc", `{"team_id":"t"}`},
		{"it rejects a desc longer than 255 characters", `{"desc":"` + strings.Repeat("x", 256) + `"}`},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})
			onideltest.SendRequest(t, ctx.api.URL, "POST", "/network/firewalls/g1/rules", `{"protocol":"tcp","subnet":"0.0.0.0","subnet_size":0}`)

			status, _ := onideltest.SendRequest(t, ctx.api.URL, "PATCH", "/network/firewalls/g1/rules/00000000-0000-4000-8000-000000000001", row.body)

			assert.Equal(t, http.StatusBadRequest, status)
		})
	}
}

func TestStubOnidelAPIListsAVMsPTRRecordsSortedByIP(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18", "main_ipv6": "2001:db8::1"})
	onideltest.SendRequest(t, ctx.api.URL, "POST", "/vm/v/rdns", `{"ip_addr":"2001:db8::1","domain":"v6.example.com"}`)
	onideltest.SendRequest(t, ctx.api.URL, "POST", "/vm/v/rdns", `{"ip_addr":"203.0.113.18","domain":"v4.example.com"}`)

	status, body := onideltest.SendRequest(t, ctx.api.URL, "GET", "/vm/v/rdns", "")

	assert.Equal(t, http.StatusOK, status)
	assert.JSONEq(t, `{"rdns":[{"ip":"2001:db8::1","domain":"v6.example.com"},{"ip":"203.0.113.18","domain":"v4.example.com"}]}`, body)
}

func TestStubOnidelAPIListsNoPTRRecordsForAVMWithoutAny(t *testing.T) {
	ctx := setupTest(t)

	status, body := onideltest.SendRequest(t, ctx.api.URL, "GET", "/vm/unknown/rdns", "")

	assert.Equal(t, http.StatusOK, status)
	assert.JSONEq(t, `{"rdns":[]}`, body)
}

func TestStubOnidelAPIRejectsAnInvalidPTRWrite(t *testing.T) {
	rows := []struct {
		name   string
		method string
		path   string
		body   string
		status int
	}{
		{"it rejects a record without an IP", "POST", "/vm/v/rdns", `{"domain":"example.com"}`, http.StatusBadRequest},
		{"it rejects a record with an invalid IP", "POST", "/vm/v/rdns", `{"ip_addr":"nope","domain":"example.com"}`, http.StatusBadRequest},
		{"it rejects a record without a domain", "POST", "/vm/v/rdns", `{"ip_addr":"203.0.113.18"}`, http.StatusBadRequest},
		{"it refuses a record for an IP the VM does not own", "POST", "/vm/v/rdns", `{"ip_addr":"198.51.100.1","domain":"example.com"}`, http.StatusUnauthorized},
		{"it refuses a record on an unknown VM", "POST", "/vm/other/rdns", `{"ip_addr":"203.0.113.18","domain":"example.com"}`, http.StatusUnauthorized},
		{"it rejects a removal for an invalid IP", "DELETE", "/vm/v/rdns/nope", "", http.StatusBadRequest},
		{"it refuses a removal for an IP the VM does not own", "DELETE", "/vm/v/rdns/198.51.100.1", "", http.StatusUnauthorized},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18", "main_ipv6": ""})

			status, _ := onideltest.SendRequest(t, ctx.api.URL, row.method, row.path, row.body)

			assert.Equal(t, []any{row.status, map[string]map[string]string{}}, []any{status, ctx.api.GetRDNS()})
		})
	}
}

func TestStubOnidelAPIOverwritesAPTRRecord(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18"})
	onideltest.SendRequest(t, ctx.api.URL, "POST", "/vm/v/rdns", `{"ip_addr":"203.0.113.18","domain":"a.example.com"}`)

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "POST", "/vm/v/rdns", `{"team_id":"t","ip_addr":"203.0.113.18","domain":"b.example.com"}`)

	assert.Equal(t, []any{http.StatusOK, map[string]map[string]string{"v": {"203.0.113.18": "b.example.com"}}},
		[]any{status, ctx.api.GetRDNS()})
}

func TestStubOnidelAPIRemovesAPTRRecord(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "main_ipv4": "203.0.113.18"})
	onideltest.SendRequest(t, ctx.api.URL, "POST", "/vm/v/rdns", `{"ip_addr":"203.0.113.18","domain":"a.example.com"}`)

	status, _ := onideltest.SendRequest(t, ctx.api.URL, "DELETE", "/vm/v/rdns/203.0.113.18?team_id=t", "")

	assert.Equal(t, []any{http.StatusNoContent, map[string]map[string]string{"v": {}}}, []any{status, ctx.api.GetRDNS()})
}

func TestStubOnidelAPIReadsAnSSHKeyInAnEnvelope(t *testing.T) {
	ctx := setupTest(t)
	onideltest.SendRequest(t, ctx.api.URL, "POST", "/ssh_keys", `{"team_id":"t","name":"me","ssh_key":"k"}`)

	status, body := onideltest.SendRequest(t, ctx.api.URL, "GET", "/ssh_keys/00000000-0000-4000-8000-000000000001?team_id=t", "")

	assert.Equal(t, http.StatusOK, status)
	assert.JSONEq(t, `{"ssh_key":{"id":"00000000-0000-4000-8000-000000000001","created":"2026-10-02T05:35:28Z","name":"me","ssh_key":"k"}}`, body)
}

func TestStubOnidelAPIReadsAFirewallGroupInAnEnvelope(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{
		"id": "g1", "description": "edge", "created": "2026-10-02T00:00:00Z", "updated": "2026-10-02T00:00:00Z",
		"instance_count": 1, "rule_count": 2,
	})

	status, body := onideltest.SendRequest(t, ctx.api.URL, "GET", "/network/firewalls/g1", "")

	assert.Equal(t, http.StatusOK, status)
	assert.JSONEq(t, `{"firewall_group":{"id":"g1","description":"edge","created":"2026-10-02T00:00:00Z",`+
		`"updated":"2026-10-02T00:00:00Z","instance_count":1,"rule_count":2}}`, body)
}

func TestStubOnidelAPISettlesAnActionOnAnActiveVMAfterOneRead(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetVM(map[string]any{"id": "v", "status": "active", "active_action_id": 42})

	_, first := onideltest.SendRequest(t, ctx.api.URL, "GET", "/vm/v", "")
	_, second := onideltest.SendRequest(t, ctx.api.URL, "GET", "/vm/v", "")

	assert.Equal(t, []string{
		`{"active_action_id":42,"id":"v","status":"active"}` + "\n",
		`{"active_action_id":null,"id":"v","status":"active"}` + "\n",
	}, []string{first, second})
}

func TestStubOnidelAPICountsAVMCreatedInAFirewallGroup(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "instance_count": 0})

	onideltest.SendRequest(t, ctx.api.URL, "POST", "/vm", `{"name":"web","location":"Sydney","cpu":2,"ram":4096,"disk":40,"os":24,"firewall_group_id":"g1"}`)

	assert.Equal(t, map[string]map[string]any{"g1": {"id": "g1", "instance_count": 1}}, ctx.api.GetFirewallGroups())
}

func TestStubOnidelAPISendsRegisteredResponsesInOrderBeforeItsRoute(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /teams", http.StatusServiceUnavailable, "", 1)
	ctx.api.RegisterResponse("GET /teams", http.StatusOK, `[]`, 1)

	first, _ := onideltest.SendRequest(t, ctx.api.URL, "GET", "/teams", "")
	second, secondBody := onideltest.SendRequest(t, ctx.api.URL, "GET", "/teams", "")
	third, thirdBody := onideltest.SendRequest(t, ctx.api.URL, "GET", "/teams", "")

	assert.Equal(t, []any{
		http.StatusServiceUnavailable, http.StatusOK, `[]`, http.StatusOK,
		`[{"id":"169b0175-361a-4ea7-b31f-d82f42bc43b1","name":"team","role":"Team Owner"}]` + "\n",
	}, []any{first, second, secondBody, third, thirdBody})
}

func TestStubOnidelAPISendsARegisteredResponseTheGivenNumberOfTimes(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("DELETE /vm/{id}", http.StatusBadRequest, "", 2)

	first, _ := onideltest.SendRequest(t, ctx.api.URL, "DELETE", "/vm/a", "")
	second, _ := onideltest.SendRequest(t, ctx.api.URL, "DELETE", "/vm/b", "")
	third, _ := onideltest.SendRequest(t, ctx.api.URL, "DELETE", "/vm/c", "")

	assert.Equal(t, []int{http.StatusBadRequest, http.StatusBadRequest, http.StatusNotFound}, []int{first, second, third})
}

func TestStubOnidelAPIDrainsTheProblemsItReports(t *testing.T) {
	ctx := setupTest(t)
	onideltest.SendRequest(t, ctx.api.URL, "GET", "/nope", "")

	first := ctx.api.DrainProblems()
	second := ctx.api.DrainProblems()

	assert.Equal(t, []any{[]string{"unhandled request: GET /nope"}, []string(nil)}, []any{first, second})
}
