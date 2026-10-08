package clienttest

import "github.com/zgeoff/cloud/provider/internal/client"

// BuildMockFirewallRuleInput returns a complete FirewallRuleInput with fixed defaults, since the provider's tests pin
// the request body as exact values. Each override changes the value in place, in order.
func BuildMockFirewallRuleInput(overrides ...func(*client.FirewallRuleInput)) client.FirewallRuleInput {
	in := client.FirewallRuleInput{TeamID: "team-a", Protocol: "tcp", Port: "443", Subnet: "203.0.113.0", SubnetSize: 24, Description: "web"}
	for _, override := range overrides {
		override(&in)
	}
	return in
}
