package client

import (
	"context"
	"net/http"
)

// OSTemplate is a prebuilt OS image a VM can be provisioned from.
type OSTemplate struct {
	ID     int    `json:"id"`
	Name   string `json:"name"`
	Family string `json:"family"`
}

// ReadOSTemplates lists the OS templates (GET /os_templates).
func (c *Client) ReadOSTemplates(ctx context.Context) ([]OSTemplate, error) {
	var templates []OSTemplate
	_, err := c.sendRequest(ctx, http.MethodGet, "/os_templates", nil, nil, &templates)
	return templates, err
}
