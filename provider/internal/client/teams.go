package client

import (
	"context"
	"net/http"
)

// Team is one team the API key's user belongs to.
type Team struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Role string `json:"role"`
}

// ReadTeams lists the caller's teams (GET /teams).
func (c *Client) ReadTeams(ctx context.Context) ([]Team, error) {
	var teams []Team
	_, err := c.sendRequest(ctx, http.MethodGet, "/teams", nil, nil, &teams)
	return teams, err
}
