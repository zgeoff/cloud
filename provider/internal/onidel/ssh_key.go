package onidel

import (
	"context"
	"strings"

	"github.com/pulumi/pulumi-go-provider/infer"

	"github.com/zgeoff/cloud/provider/internal/client"
)

// SSHKey is onidel:index:SshKey, a team SSH public key.
type SSHKey struct{}

// SSHKeyArgs are the SshKey inputs. Both are updatable in place.
type SSHKeyArgs struct {
	Name      string `pulumi:"name"`
	PublicKey string `pulumi:"publicKey"`
}

// SSHKeyState is the SshKey state.
type SSHKeyState struct {
	SSHKeyArgs
	Created string `pulumi:"created"`
}

// Annotate sets the token and docs.
func (k *SSHKey) Annotate(a infer.Annotator) {
	a.SetToken("index", "SshKey")
	a.Describe(k, "An SSH public key in the Onidel team, for VM provisioning.")
}

// Annotate documents the inputs.
func (a *SSHKeyArgs) Annotate(an infer.Annotator) {
	an.Describe(&a.Name, "Display name of the key.")
	an.Describe(&a.PublicKey, "OpenSSH public key, e.g. `ssh-ed25519 AAAA... user@host`.")
}

// Create adds the key.
func (SSHKey) Create(ctx context.Context, req infer.CreateRequest[SSHKeyArgs]) (infer.CreateResponse[SSHKeyState], error) {
	if req.DryRun {
		return infer.CreateResponse[SSHKeyState]{Output: SSHKeyState{SSHKeyArgs: req.Inputs}}, nil
	}
	api, cfg := getClient(ctx)
	teamID, err := cfg.resolveTeamID(ctx)
	if err != nil {
		return infer.CreateResponse[SSHKeyState]{}, err
	}
	key, err := api.CreateSSHKey(ctx, client.SSHKeyInput{
		TeamID: teamID, Name: req.Inputs.Name, PublicKey: req.Inputs.PublicKey,
	})
	if err != nil {
		return infer.CreateResponse[SSHKeyState]{}, err
	}
	return infer.CreateResponse[SSHKeyState]{ID: key.ID, Output: buildSSHKeyState(req.Inputs, key)}, nil
}

// Read refreshes or imports the key.
func (SSHKey) Read(
	ctx context.Context, req infer.ReadRequest[SSHKeyArgs, SSHKeyState],
) (infer.ReadResponse[SSHKeyArgs, SSHKeyState], error) {
	api, cfg := getClient(ctx)
	key, err := api.ReadSSHKey(ctx, req.ID, cfg.TeamID)
	if client.IsNotFound(err) {
		return infer.ReadResponse[SSHKeyArgs, SSHKeyState]{}, nil
	}
	if err != nil {
		return infer.ReadResponse[SSHKeyArgs, SSHKeyState]{}, err
	}
	state := buildSSHKeyState(req.Inputs, key)
	return infer.ReadResponse[SSHKeyArgs, SSHKeyState]{ID: key.ID, Inputs: state.SSHKeyArgs, State: state}, nil
}

// Update renames the key or swaps its public key.
func (SSHKey) Update(
	ctx context.Context, req infer.UpdateRequest[SSHKeyArgs, SSHKeyState],
) (infer.UpdateResponse[SSHKeyState], error) {
	next := SSHKeyState{SSHKeyArgs: req.Inputs, Created: req.State.Created}
	if req.DryRun {
		return infer.UpdateResponse[SSHKeyState]{Output: next}, nil
	}
	api, cfg := getClient(ctx)
	teamID, err := cfg.resolveTeamID(ctx)
	if err != nil {
		return infer.UpdateResponse[SSHKeyState]{}, err
	}
	err = api.UpdateSSHKey(ctx, req.ID, client.SSHKeyInput{
		TeamID: teamID, Name: req.Inputs.Name, PublicKey: req.Inputs.PublicKey,
	})
	if err != nil {
		return infer.UpdateResponse[SSHKeyState]{}, err
	}
	return infer.UpdateResponse[SSHKeyState]{Output: next}, nil
}

// Delete removes the key.
func (SSHKey) Delete(ctx context.Context, req infer.DeleteRequest[SSHKeyState]) (infer.DeleteResponse, error) {
	api, cfg := getClient(ctx)
	err := api.RemoveSSHKey(ctx, req.ID, cfg.TeamID)
	if client.IsNotFound(err) {
		err = nil
	}
	return infer.DeleteResponse{}, err
}

// buildSSHKeyState maps an API key to state. The public key keeps the program's
// spelling when the API returns it with only whitespace changed.
func buildSSHKeyState(in SSHKeyArgs, key client.SSHKey) SSHKeyState {
	publicKey := key.PublicKey
	if strings.TrimSpace(in.PublicKey) == strings.TrimSpace(key.PublicKey) && in.PublicKey != "" {
		publicKey = in.PublicKey
	}
	return SSHKeyState{
		SSHKeyArgs: SSHKeyArgs{Name: key.Name, PublicKey: publicKey},
		Created:    key.Created,
	}
}
