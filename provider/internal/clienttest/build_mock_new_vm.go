package clienttest

import "github.com/zgeoff/cloud/provider/internal/onidelapi"

// BuildMockNewVM returns a complete NewVM with fixed defaults, since the provider's tests pin
// the request body as exact values. Each override changes the value in place, in order.
func BuildMockNewVM(overrides ...func(*onidelapi.NewVM)) onidelapi.NewVM {
	in := onidelapi.NewVM{Name: "web", Location: "Sydney", CPU: 1, RAM: 1024, Disk: 20, Os: new(int64(24))}
	for _, override := range overrides {
		override(&in)
	}
	return in
}
