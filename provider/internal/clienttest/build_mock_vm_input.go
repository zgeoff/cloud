package clienttest

import "github.com/zgeoff/cloud/provider/internal/client"

// BuildMockVMInput returns a complete VMInput with fixed defaults, since the provider's tests pin
// the request body as exact values. Each override changes the value in place, in order.
func BuildMockVMInput(overrides ...func(*client.VMInput)) client.VMInput {
	in := client.VMInput{Name: "web", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20, OS: new(24)}
	for _, override := range overrides {
		override(&in)
	}
	return in
}
