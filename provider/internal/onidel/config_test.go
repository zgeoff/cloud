package onidel

import (
	"context"
	"testing"

	p "github.com/pulumi/pulumi-go-provider"
	"github.com/pulumi/pulumi-go-provider/infer"
)

func TestConfigDiffUpdatesInPlace(t *testing.T) {
	cfg := &Config{}
	resp, err := cfg.Diff(context.Background(), infer.DiffRequest[*Config, *Config]{
		State:  &Config{APIKey: "old"},
		Inputs: &Config{APIKey: "new"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !resp.HasChanges || resp.DeleteBeforeReplace || resp.DetailedDiff["apiKey"].Kind != p.Update {
		t.Errorf("Diff = %+v; want an in-place update of apiKey", resp)
	}
	resp, _ = cfg.Diff(context.Background(), infer.DiffRequest[*Config, *Config]{
		State: &Config{APIKey: "same"}, Inputs: &Config{APIKey: "same"},
	})
	if resp.HasChanges {
		t.Errorf("Diff of equal configs = %+v; want no changes", resp)
	}
}
