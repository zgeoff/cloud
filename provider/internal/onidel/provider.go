// Package onidel is the partial Onidel Pulumi provider, built on pulumi-go-provider's
// infer package. Every resource token lives in the index module (onidel:index:*).
package onidel

import (
	"context"
	"time"

	p "github.com/pulumi/pulumi-go-provider"
	"github.com/pulumi/pulumi-go-provider/infer"
)

// Name is the Pulumi package name.
const Name = "onidel"

// NodePackageName is the npm name of the generated TypeScript SDK.
const NodePackageName = "@zgeoff/pulumi-onidel"

// pulumiNodeSDKVersion pins the SDK's @pulumi/pulumi dependency to an exact version.
const pulumiNodeSDKVersion = "3.251.0"

// Options changes how NewWithOptions builds the provider. The zero value builds the
// provider New does.
type Options struct {
	// Sleep, when set, replaces the API client's wait between polls and retries.
	Sleep func(ctx context.Context, d time.Duration) error
}

// New builds the provider.
func New() (p.Provider, error) {
	return NewWithOptions(Options{})
}

// NewWithOptions builds the provider with opts.
func NewWithOptions(opts Options) (p.Provider, error) {
	return infer.NewProviderBuilder().
		WithDisplayName("Onidel").
		WithDescription("A partial provider for the Onidel cloud API: VMs, SSH keys, firewalls and rDNS.").
		WithNamespace("zgeoff").
		WithRepository("https://github.com/zgeoff/cloud").
		WithLicense("MIT").
		WithKeywords("onidel", "category/cloud").
		WithLanguageMap(map[string]any{
			"nodejs": map[string]any{
				"packageName":          NodePackageName,
				"respectSchemaVersion": true,
				"dependencies": map[string]string{
					"@pulumi/pulumi": pulumiNodeSDKVersion,
				},
				// Exact versions: the repo bans ranges, and TypeScript matches the root.
				"devDependencies": map[string]string{
					"@types/node": "24.13.6",
					"typescript":  "7.0.2",
				},
				"typescriptVersion": "7.0.2",
			},
		}).
		WithGoImportPath("github.com/zgeoff/cloud/sdk/go/onidel").
		WithConfig(infer.Config(&Config{sleep: opts.Sleep})).
		WithResources(
			infer.Resource(SSHKey{}),
			infer.Resource(VM{}),
			infer.Resource(FirewallGroup{}),
			infer.Resource(FirewallRule{}),
			infer.Resource(RDNS{}),
		).
		Build()
}
