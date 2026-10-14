package clienttest

import "github.com/zgeoff/cloud/provider/internal/onidelapi"

// BuildMockUpdateFirewallGroup returns a complete UpdateFirewallGroup with fixed defaults, since the provider's tests pin
// the request body as exact values. Each override changes the value in place, in order.
func BuildMockUpdateFirewallGroup(overrides ...func(*onidelapi.UpdateFirewallGroup)) onidelapi.UpdateFirewallGroup {
	in := onidelapi.UpdateFirewallGroup{TeamID: "team-a", Description: "edge"}
	for _, override := range overrides {
		override(&in)
	}
	return in
}
