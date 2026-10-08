package clienttest_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/clienttest"
)

func TestBuildMockSSHKeyInputBuildsADefaultSSHKeyInput(t *testing.T) {
	assert.Equal(t, client.SSHKeyInput{TeamID: "team-a", Name: "me", PublicKey: "ssh-ed25519 AAAA me@host"}, clienttest.BuildMockSSHKeyInput())
}

func TestBuildMockSSHKeyInputAppliesOverridesOnTopOfTheDefaults(t *testing.T) {
	assert.Equal(t, client.SSHKeyInput{Name: "me-2", PublicKey: "ssh-ed25519 AAAA me@host"}, clienttest.BuildMockSSHKeyInput(func(in *client.SSHKeyInput) { in.TeamID, in.Name = "", "me-2" }))
}
