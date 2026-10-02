package client

import (
	"context"
	"net/http"
	"net/url"
)

// SSHKey is a team SSH public key.
type SSHKey struct {
	ID        string `json:"id"`
	Created   string `json:"created"`
	Name      string `json:"name"`
	PublicKey string `json:"ssh_key"`
}

// SSHKeyInput is the body of a create or update. The API requires all three fields
// on both.
type SSHKeyInput struct {
	TeamID    string `json:"team_id"`
	Name      string `json:"name"`
	PublicKey string `json:"ssh_key"`
}

type sshKeyEnvelope struct {
	SSHKey SSHKey `json:"ssh_key"`
}

// CreateSSHKey adds a key (POST /ssh_keys).
func (c *Client) CreateSSHKey(ctx context.Context, in SSHKeyInput) (SSHKey, error) {
	var out sshKeyEnvelope
	_, err := c.sendRequest(ctx, http.MethodPost, "/ssh_keys", nil, in, &out)
	return out.SSHKey, err
}

// ReadSSHKey gets one key (GET /ssh_keys/{id}).
func (c *Client) ReadSSHKey(ctx context.Context, id, teamID string) (SSHKey, error) {
	var out sshKeyEnvelope
	_, err := c.sendRequest(ctx, http.MethodGet, "/ssh_keys/"+url.PathEscape(id),
		buildTeamQuery(teamID), nil, &out)
	return out.SSHKey, err
}

// UpdateSSHKey renames a key or replaces its public key (PATCH /ssh_keys/{id}).
func (c *Client) UpdateSSHKey(ctx context.Context, id string, in SSHKeyInput) error {
	_, err := c.sendRequest(ctx, http.MethodPatch, "/ssh_keys/"+url.PathEscape(id), nil, in, nil)
	return err
}

// RemoveSSHKey deletes a key (DELETE /ssh_keys/{id}).
func (c *Client) RemoveSSHKey(ctx context.Context, id, teamID string) error {
	_, err := c.sendRequest(ctx, http.MethodDelete, "/ssh_keys/"+url.PathEscape(id),
		buildTeamQuery(teamID), nil, nil)
	return err
}
