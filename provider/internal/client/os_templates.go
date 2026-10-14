package client

import (
	"context"

	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

// ReadOSTemplates lists the OS templates (GET /os_templates).
func (c *Client) ReadOSTemplates(ctx context.Context) (onidelapi.OSTemplate, error) {
	return decodeResponse[onidelapi.OSTemplate](c.api.GetOSTemplate(ctx))
}
