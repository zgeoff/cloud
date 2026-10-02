// Command pulumi-resource-onidel is the Onidel Pulumi resource provider plugin.
package main

import (
	"context"
	"fmt"
	"os"

	p "github.com/pulumi/pulumi-go-provider"

	"github.com/zgeoff/cloud/provider/internal/onidel"
)

// Version is set at build time with -ldflags "-X main.Version=...".
var Version = "0.1.0"

func main() {
	provider, err := onidel.New()
	if err != nil {
		fmt.Fprintf(os.Stderr, "build provider: %s\n", err)
		os.Exit(1)
	}
	if err := p.RunProvider(context.Background(), onidel.Name, Version, provider); err != nil {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(1)
	}
}
