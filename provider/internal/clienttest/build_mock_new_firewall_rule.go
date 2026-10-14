package clienttest

import "github.com/zgeoff/cloud/provider/internal/onidelapi"

// BuildMockNewFirewallRule returns a complete NewFirewallRule with fixed defaults, since the provider's tests pin
// the request body as exact values. Each override changes the value in place, in order.
func BuildMockNewFirewallRule(overrides ...func(*onidelapi.NewFirewallRule)) onidelapi.NewFirewallRule {
	in := onidelapi.NewFirewallRule{TeamID: "team-a", Protocol: "tcp", Port: "443", Subnet: "203.0.113.0", SubnetSize: 24, Desc: "web"}
	for _, override := range overrides {
		override(&in)
	}
	return in
}
