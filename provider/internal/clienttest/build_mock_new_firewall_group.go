package clienttest

import "github.com/zgeoff/cloud/provider/internal/onidelapi"

// BuildMockNewFirewallGroup returns a complete NewFirewallGroup with fixed defaults, since the provider's tests pin
// the request body as exact values. Each override changes the value in place, in order.
func BuildMockNewFirewallGroup(overrides ...func(*onidelapi.NewFirewallGroup)) onidelapi.NewFirewallGroup {
	in := onidelapi.NewFirewallGroup{TeamID: "team-a", Description: "edge"}
	for _, override := range overrides {
		override(&in)
	}
	return in
}
