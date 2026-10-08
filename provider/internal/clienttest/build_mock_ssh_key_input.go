package clienttest

import "github.com/zgeoff/cloud/provider/internal/client"

// BuildMockSSHKeyInput returns a complete SSHKeyInput with fixed defaults, since the provider's tests pin
// the request body as exact values. Each override changes the value in place, in order.
func BuildMockSSHKeyInput(overrides ...func(*client.SSHKeyInput)) client.SSHKeyInput {
	in := client.SSHKeyInput{TeamID: "team-a", Name: "me", PublicKey: "ssh-ed25519 AAAA me@host"}
	for _, override := range overrides {
		override(&in)
	}
	return in
}
