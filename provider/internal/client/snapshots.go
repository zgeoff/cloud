package client

import (
	"context"

	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

// CreateSnapshot starts a snapshot of a VM's system disk (POST /vm/{id}/snapshot). The
// snapshot lists as pending until Onidel finishes it.
func (c *Client) CreateSnapshot(ctx context.Context, vmID string, in onidelapi.NewSnapshot) (onidelapi.SnapshotStarted, error) {
	return decodeResponse[onidelapi.SnapshotStarted](c.api.SnapshotVM(ctx, vmID, in))
}

// ReadSnapshots lists the account's snapshots (GET /snapshots).
func (c *Client) ReadSnapshots(ctx context.Context) ([]onidelapi.Snapshot, error) {
	return decodeResponse[[]onidelapi.Snapshot](c.api.GetSnapshots(ctx))
}
