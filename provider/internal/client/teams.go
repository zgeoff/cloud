package client

import (
	"context"

	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

// ReadTeams lists the caller's teams (GET /teams).
func (c *Client) ReadTeams(ctx context.Context) ([]onidelapi.Team, error) {
	return decodeResponse[[]onidelapi.Team](c.api.GetTeams(ctx))
}
