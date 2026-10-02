package onidel

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"

	"github.com/pulumi/pulumi-go-provider/infer"

	"github.com/zgeoff/cloud/provider/internal/client"
)

// APIKeyEnv is the environment fallback for the apiKey config.
const APIKeyEnv = "ONIDEL_API_KEY"

// Config is the provider configuration.
type Config struct {
	APIKey   string `pulumi:"apiKey,optional" provider:"secret"`
	TeamID   string `pulumi:"teamId,optional"`
	Endpoint string `pulumi:"endpoint,optional"`

	client *client.Client

	teamOnce sync.Once
	teamID   string
	teamErr  error
}

// Annotate documents the config for the schema.
func (c *Config) Annotate(a infer.Annotator) {
	a.Describe(&c.APIKey, "Onidel API key. Falls back to the "+APIKeyEnv+" environment variable.")
	a.SetDefault(&c.APIKey, nil, APIKeyEnv)
	a.Describe(&c.TeamID, "Team ID to act in. When unset, the provider uses the API key's only team.")
	a.Describe(&c.Endpoint, "API base URL. Defaults to "+client.DefaultBaseURL+".")
}

// Configure builds the API client.
func (c *Config) Configure(context.Context) error {
	if c.APIKey == "" {
		c.APIKey = os.Getenv(APIKeyEnv)
	}
	if c.APIKey == "" {
		return errors.New("onidel: set the apiKey config or " + APIKeyEnv)
	}
	c.client = client.New(c.Endpoint, c.APIKey)
	return nil
}

// getClient returns the configured API client and the config, with the team
// resolved. Onidel rejects writes without a team_id (401 on create, 404 on
// delete), so every call carries one. A failed lookup leaves the team empty, and
// the call then fails with the API's own error.
func getClient(ctx context.Context) (*client.Client, *Config) {
	cfg := infer.GetConfig[*Config](ctx)
	_, _ = cfg.resolveTeamID(ctx)
	return cfg.client, cfg
}

// resolveTeamID returns the team for endpoints that require one: the configured
// teamId, or the caller's only team.
func (c *Config) resolveTeamID(ctx context.Context) (string, error) {
	c.teamOnce.Do(func() {
		if c.TeamID != "" {
			c.teamID = c.TeamID
			return
		}
		teams, err := c.client.ReadTeams(ctx)
		switch {
		case err != nil:
			c.teamErr = err
		case len(teams) == 1:
			c.teamID = teams[0].ID
		default:
			c.teamErr = fmt.Errorf("onidel: the API key can see %d teams; set the teamId config", len(teams))
		}
	})
	return c.teamID, c.teamErr
}
