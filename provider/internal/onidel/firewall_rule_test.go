package onidel_test

import (
	"net/http"
	"testing"

	p "github.com/pulumi/pulumi-go-provider"
	presource "github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/onidel"
	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestFirewallRuleCreateKeepsTheProgramsICMPSpellingOnAV6Subnet(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})

	created, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:FirewallRule", "icmp6"),
		Properties: onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0}),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		"g1/00000000-0000-4000-8000-000000000001",
		map[string]any{
			"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0.0,
			"ruleId": "00000000-0000-4000-8000-000000000001", "ipType": "v6", "action": "allow",
		},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "POST", Path: "/network/firewalls/g1/rules", Body: map[string]any{
				"team_id": "team-a", "protocol": "icmp", "subnet": "::", "subnet_size": 0.0,
			}},
		},
	}, []any{created.ID, onideltest.ToPlain(created.Properties), ctx.api.GetRequests()})
}

func TestFirewallRuleCreateRecordsAPortAndDescription(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})

	created, err := ctx.server.Create(p.CreateRequest{
		Urn: onideltest.BuildURN("onidel:index:FirewallRule", "https"),
		Properties: onideltest.BuildProps(map[string]any{
			"firewallId": "g1", "protocol": "tcp", "port": "443", "subnet": "0.0.0.0", "subnetSize": 0, "description": "web",
		}),
	})

	require.NoError(t, err)
	assert.Equal(t, map[string]any{
		"firewallId": "g1", "protocol": "tcp", "port": "443", "subnet": "0.0.0.0", "subnetSize": 0.0, "description": "web",
		"ruleId": "00000000-0000-4000-8000-000000000001", "ipType": "v4", "action": "allow",
	}, onideltest.ToPlain(created.Properties))
}

func TestFirewallRuleCreatePreviewSendsNothing(t *testing.T) {
	ctx := setupTest(t)

	created, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:FirewallRule", "icmp6"),
		Properties: onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0}),
		DryRun:     true,
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{
			"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0.0,
			"ruleId": presource.Computed{Element: presource.NewProperty("")},
			"ipType": presource.Computed{Element: presource.NewProperty("")},
			"action": presource.Computed{Element: presource.NewProperty("")},
		},
		[]onideltest.Request(nil),
	}, []any{onideltest.ToPlain(created.Properties), ctx.api.GetRequests()})
}

func TestFirewallRuleCreateFailsForAMissingGroup(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.server.Create(p.CreateRequest{
		Urn:        onideltest.BuildURN("onidel:index:FirewallRule", "icmp6"),
		Properties: onideltest.BuildProps(map[string]any{"firewallId": "missing", "protocol": "icmp", "subnet": "::", "subnetSize": 0}),
	})

	assert.EqualError(t, err, "onidel: POST /network/firewalls/missing/rules: HTTP 404")
}

func TestFirewallRuleRefreshShowsNoDriftForICMPOnAV6Subnet(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})
	urn := onideltest.BuildURN("onidel:index:FirewallRule", "icmp6")
	inputs := map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0}
	created, err := ctx.server.Create(p.CreateRequest{Urn: urn, Properties: onideltest.BuildProps(inputs)})
	require.NoError(t, err)

	read, err := ctx.server.Read(p.ReadRequest{
		ID: created.ID, Urn: urn, Properties: created.Properties, Inputs: onideltest.BuildProps(inputs),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		"g1/00000000-0000-4000-8000-000000000001",
		map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0.0},
		map[string]any{
			"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0.0,
			"ruleId": "00000000-0000-4000-8000-000000000001", "ipType": "v6", "action": "allow",
		},
	}, []any{read.ID, onideltest.ToPlain(read.Inputs), onideltest.ToPlain(read.Properties)})
}

func TestFirewallRuleImportAdoptsTheAPIsSpellingByCompositeID(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})
	urn := onideltest.BuildURN("onidel:index:FirewallRule", "icmp6")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0}),
	})
	require.NoError(t, err)

	imported, err := ctx.server.Read(p.ReadRequest{ID: created.ID, Urn: urn})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{"firewallId": "g1", "protocol": "ipv6-icmp", "subnet": "::", "subnetSize": 0.0},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "POST", Path: "/network/firewalls/g1/rules", Body: map[string]any{
				"team_id": "team-a", "protocol": "icmp", "subnet": "::", "subnet_size": 0.0,
			}},
			{
				Method: "GET", Path: "/network/firewalls/g1/rules/00000000-0000-4000-8000-000000000001",
				Query: "team_id=team-a",
			},
		},
	}, []any{onideltest.ToPlain(imported.Inputs), ctx.api.GetRequests()})
}

func TestFirewallRuleReadReportsADeletedRuleAsGone(t *testing.T) {
	ctx := setupTest(t)

	read, err := ctx.server.Read(p.ReadRequest{ID: "g1/missing", Urn: onideltest.BuildURN("onidel:index:FirewallRule", "r")})

	require.NoError(t, err)
	assert.Equal(t, "", read.ID)
}

func TestFirewallRuleReadFailsWhenTheAPIFails(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("GET /network/firewalls/{id}/rules/{rule}", http.StatusInternalServerError, "", 1)

	_, err := ctx.server.Read(p.ReadRequest{ID: "g1/r1", Urn: onideltest.BuildURN("onidel:index:FirewallRule", "r")})

	assert.EqualError(t, err, "onidel: GET /network/firewalls/g1/rules/r1: HTTP 500")
}

func TestFirewallRuleReadRejectsAMalformedID(t *testing.T) {
	rows := []struct {
		name string
		id   string
	}{
		{"it rejects an ID without a slash", "no-slash"},
		{"it rejects an ID without a group", "/r1"},
		{"it rejects an ID without a rule", "g1/"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)

			_, err := ctx.server.Read(p.ReadRequest{ID: row.id, Urn: onideltest.BuildURN("onidel:index:FirewallRule", "r")})

			var idErr *onidel.FirewallRuleIDError
			require.ErrorAs(t, err, &idErr)
			assert.Equal(t, &onidel.FirewallRuleIDError{ID: row.id}, idErr)
			assert.EqualError(t, err, `onidel: firewall rule ID "`+row.id+`" is not <firewallId>/<ruleId>`)
			assert.Equal(t, []onideltest.Request(nil), ctx.api.GetRequests())
		})
	}
}

func TestFirewallRuleUpdateRejectsAMalformedID(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.server.Update(p.UpdateRequest{
		ID: "no-slash", Urn: onideltest.BuildURN("onidel:index:FirewallRule", "r"),
		State: onideltest.BuildProps(map[string]any{
			"firewallId": "g1", "protocol": "tcp", "port": "443", "subnet": "0.0.0.0", "subnetSize": 0,
			"ruleId": "r1", "ipType": "v4", "action": "allow",
		}),
		OldInputs: onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "tcp", "port": "443", "subnet": "0.0.0.0", "subnetSize": 0}),
		Inputs: onideltest.BuildProps(map[string]any{
			"firewallId": "g1", "protocol": "tcp", "port": "443", "subnet": "0.0.0.0", "subnetSize": 0, "description": "web",
		}),
	})

	var idErr *onidel.FirewallRuleIDError
	require.ErrorAs(t, err, &idErr)
	assert.Equal(t, &onidel.FirewallRuleIDError{ID: "no-slash"}, idErr)
	assert.EqualError(t, err, `onidel: firewall rule ID "no-slash" is not <firewallId>/<ruleId>`)
	assert.Equal(t, []onideltest.Request(nil), ctx.api.GetRequests())
}

func TestFirewallRuleDeleteRejectsAMalformedID(t *testing.T) {
	ctx := setupTest(t)

	err := ctx.server.Delete(p.DeleteRequest{
		ID: "no-slash", Urn: onideltest.BuildURN("onidel:index:FirewallRule", "r"),
		Properties: onideltest.BuildProps(map[string]any{
			"firewallId": "g1", "protocol": "tcp", "port": "443", "subnet": "0.0.0.0", "subnetSize": 0,
			"ruleId": "r1", "ipType": "v4", "action": "allow",
		}),
	})

	var idErr *onidel.FirewallRuleIDError
	require.ErrorAs(t, err, &idErr)
	assert.Equal(t, &onidel.FirewallRuleIDError{ID: "no-slash"}, idErr)
	assert.EqualError(t, err, `onidel: firewall rule ID "no-slash" is not <firewallId>/<ruleId>`)
	assert.Equal(t, []onideltest.Request(nil), ctx.api.GetRequests())
}

func TestFirewallRuleReadDropsAPortTheAPIReportsOnAnICMPRule(t *testing.T) {
	ctx := setupTest(t)
	// Not seen live: covers the program leaving the port unset on an ICMP rule the
	// API reports with one.
	ctx.api.RegisterResponse("GET /network/firewalls/{id}/rules/{rule}", http.StatusOK,
		`{"firewall_rule":{"id":"r1","group":"g1","ip_type":"v4","action":"allow","protocol":"icmp","port":"0",`+
			`"subnet":"0.0.0.0","subnet_size":0,"desc":""}}`, 1)

	read, err := ctx.server.Read(p.ReadRequest{
		ID: "g1/r1", Urn: onideltest.BuildURN("onidel:index:FirewallRule", "icmp"),
		Inputs: onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "0.0.0.0", "subnetSize": 0}),
	})

	require.NoError(t, err)
	assert.Equal(t, map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "0.0.0.0", "subnetSize": 0.0}, onideltest.ToPlain(read.Inputs))
}

func TestFirewallRuleDeleteFailsWhenTheAPIRefuses(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.RegisterResponse("DELETE /network/firewalls/{id}/rules/{rule}", http.StatusUnauthorized, "", 1)

	err := ctx.server.Delete(p.DeleteRequest{
		ID: "g1/r1", Urn: onideltest.BuildURN("onidel:index:FirewallRule", "r"),
		Properties: onideltest.BuildProps(map[string]any{
			"firewallId": "g1", "protocol": "tcp", "port": "443", "subnet": "0.0.0.0", "subnetSize": 0,
			"ruleId": "r1", "ipType": "v4", "action": "allow",
		}),
	})

	assert.EqualError(t, err, "onidel: DELETE /network/firewalls/g1/rules/r1: HTTP 401")
}

func TestFirewallRuleDiffUpdatesOnlyTheDescriptionInPlace(t *testing.T) {
	rows := []struct {
		name   string
		inputs map[string]any
		want   p.DiffResponse
	}{
		{
			"it adds a description in place",
			map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0, "description": "ping"},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"description": {Kind: p.Add}}},
		},
		{
			"it replaces the rule for a new port and protocol",
			map[string]any{"firewallId": "g1", "protocol": "tcp", "port": "443", "subnet": "::", "subnetSize": 0},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{
				"port": {Kind: p.AddReplace}, "protocol": {Kind: p.UpdateReplace},
			}},
		},
		{
			"it replaces the rule for a new subnet",
			map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "0.0.0.0", "subnetSize": 0},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"subnet": {Kind: p.UpdateReplace}}},
		},
		{
			"it replaces the rule for a new group",
			map[string]any{"firewallId": "g2", "protocol": "icmp", "subnet": "::", "subnetSize": 0},
			p.DiffResponse{HasChanges: true, DetailedDiff: map[string]p.PropertyDiff{"firewallId": {Kind: p.UpdateReplace}}},
		},
		{
			"it reports no change for the same inputs",
			map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0},
			p.DiffResponse{DetailedDiff: map[string]p.PropertyDiff{}},
		},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)

			diff, err := ctx.server.Diff(p.DiffRequest{
				ID: "g1/r1", Urn: onideltest.BuildURN("onidel:index:FirewallRule", "icmp6"),
				State: onideltest.BuildProps(map[string]any{
					"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0,
					"ruleId": "r1", "ipType": "v6", "action": "allow",
				}),
				OldInputs: onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0}),
				Inputs:    onideltest.BuildProps(row.inputs),
			})

			require.NoError(t, err)
			assert.Equal(t, row.want, diff)
		})
	}
}

func TestFirewallRuleUpdateChangesTheDescription(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})
	urn := onideltest.BuildURN("onidel:index:FirewallRule", "icmp6")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0}),
	})
	require.NoError(t, err)

	updated, err := ctx.server.Update(p.UpdateRequest{
		ID: created.ID, Urn: urn, State: created.Properties,
		OldInputs: onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0}),
		Inputs:    onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0, "description": "ping"}),
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{
			"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0.0, "description": "ping",
			"ruleId": "00000000-0000-4000-8000-000000000001", "ipType": "v6", "action": "allow",
		},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "POST", Path: "/network/firewalls/g1/rules", Body: map[string]any{
				"team_id": "team-a", "protocol": "icmp", "subnet": "::", "subnet_size": 0.0,
			}},
			{
				Method: "PATCH", Path: "/network/firewalls/g1/rules/00000000-0000-4000-8000-000000000001",
				Body: map[string]any{"team_id": "team-a", "desc": "ping"},
			},
		},
	}, []any{onideltest.ToPlain(updated.Properties), ctx.api.GetRequests()})
}

func TestFirewallRuleUpdatePreviewSendsNothing(t *testing.T) {
	ctx := setupTest(t)

	updated, err := ctx.server.Update(p.UpdateRequest{
		ID: "g1/r1", Urn: onideltest.BuildURN("onidel:index:FirewallRule", "icmp6"),
		State: onideltest.BuildProps(map[string]any{
			"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0,
			"ruleId": "r1", "ipType": "v6", "action": "allow",
		}),
		OldInputs: onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0}),
		Inputs:    onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0, "description": "ping"}),
		DryRun:    true,
	})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]any{
			"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0.0, "description": "ping",
			"ruleId": "r1", "ipType": "v6", "action": "allow",
		},
		[]onideltest.Request(nil),
	}, []any{onideltest.ToPlain(updated.Properties), ctx.api.GetRequests()})
}

func TestFirewallRuleUpdateFailsWhenTheRuleIsGone(t *testing.T) {
	ctx := setupTest(t)

	_, err := ctx.server.Update(p.UpdateRequest{
		ID: "g1/missing", Urn: onideltest.BuildURN("onidel:index:FirewallRule", "icmp6"),
		State: onideltest.BuildProps(map[string]any{
			"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0,
			"ruleId": "missing", "ipType": "v6", "action": "allow",
		}),
		OldInputs: onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0}),
		Inputs:    onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0, "description": "ping"}),
	})

	assert.EqualError(t, err, "onidel: PATCH /network/firewalls/g1/rules/missing: HTTP 404")
}

func TestFirewallRuleDeleteRemovesTheRuleFromTheTeam(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})
	urn := onideltest.BuildURN("onidel:index:FirewallRule", "icmp6")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0}),
	})
	require.NoError(t, err)

	err = ctx.server.Delete(p.DeleteRequest{ID: created.ID, Urn: urn, Properties: created.Properties})

	require.NoError(t, err)
	assert.Equal(t, []any{
		map[string]map[string]any{},
		[]onideltest.Request{
			{Method: "GET", Path: "/teams"},
			{Method: "POST", Path: "/network/firewalls/g1/rules", Body: map[string]any{
				"team_id": "team-a", "protocol": "icmp", "subnet": "::", "subnet_size": 0.0,
			}},
			{
				Method: "DELETE", Path: "/network/firewalls/g1/rules/00000000-0000-4000-8000-000000000001",
				Query: "team_id=team-a",
			},
		},
	}, []any{ctx.api.GetFirewallRules(), ctx.api.GetRequests()})
}

func TestFirewallRuleDeleteAcceptsARuleThatIsAlreadyGone(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetTeams(map[string]any{"id": "team-a", "name": "team", "role": "Team Owner"})

	err := ctx.server.Delete(p.DeleteRequest{
		ID: "g1/missing", Urn: onideltest.BuildURN("onidel:index:FirewallRule", "r"),
		Properties: onideltest.BuildProps(map[string]any{
			"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0,
			"ruleId": "missing", "ipType": "v6", "action": "allow",
		}),
	})

	require.NoError(t, err)
	assert.Equal(t, []onideltest.Request{{Method: "GET", Path: "/teams"}, {Method: "DELETE", Path: "/network/firewalls/g1/rules/missing", Query: "team_id=team-a"}}, ctx.api.GetRequests())
}

func TestFirewallRuleReadAfterDeleteReportsTheRuleAsGone(t *testing.T) {
	ctx := setupTest(t)
	ctx.api.SetFirewallGroup(map[string]any{"id": "g1", "rule_count": 0})
	urn := onideltest.BuildURN("onidel:index:FirewallRule", "icmp6")
	created, err := ctx.server.Create(p.CreateRequest{
		Urn: urn, Properties: onideltest.BuildProps(map[string]any{"firewallId": "g1", "protocol": "icmp", "subnet": "::", "subnetSize": 0}),
	})
	require.NoError(t, err)
	require.NoError(t, ctx.server.Delete(p.DeleteRequest{ID: created.ID, Urn: urn, Properties: created.Properties}))

	read, err := ctx.server.Read(p.ReadRequest{ID: created.ID, Urn: urn})

	require.NoError(t, err)
	assert.Equal(t, "", read.ID)
}
