package clienttest

import "github.com/zgeoff/cloud/provider/internal/client"

// BuildMockFirewallGroupInput returns a complete FirewallGroupInput with fixed defaults, since the provider's tests pin
// the request body as exact values. Each override changes the value in place, in order.
func BuildMockFirewallGroupInput(overrides ...func(*client.FirewallGroupInput)) client.FirewallGroupInput {
	in := client.FirewallGroupInput{TeamID: "team-a", Description: "edge"}
	for _, override := range overrides {
		override(&in)
	}
	return in
}
