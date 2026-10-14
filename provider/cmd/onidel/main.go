// Command onidel runs one-off Onidel actions through the provider's client, for the
// operator rather than for Pulumi.
//
//	onidel snapshot [-topology path] [-endpoint url] <name>
//
// snapshot takes an Onidel snapshot of geoffcloud's system disk (vda) before a risky
// host change, then lists the account's snapshots. vdb, imp's pool, is not in it:
// imp's restic backups cover the imps. The VM is the one packages/topology names, and
// the API key comes from ONIDEL_API_KEY, so run it through op:
//
//	op run --env-file=.env -- bun run onidel:snapshot pre-<change>
//
// It prints names, dates and statuses only, never a VM object, which holds the root
// password, and never the key.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/zgeoff/cloud/provider/internal/client"
	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

const usage = `usage: onidel snapshot [-topology path] [-endpoint url] <name>, such as pre-imp-1.1`

func main() {
	os.Exit(run(context.Background(), os.Args[1:], os.Getenv("ONIDEL_API_KEY"), os.Stdout, os.Stderr))
}

// errUsage is a command line that names no action, or an action without its arguments.
var errUsage = errors.New(usage)

func run(ctx context.Context, args []string, apiKey string, stdout, stderr io.Writer) int {
	err := errUsage
	if len(args) > 0 && args[0] == "snapshot" {
		err = runSnapshot(ctx, args[1:], apiKey, stdout)
	}
	switch {
	case errors.Is(err, errUsage), errors.Is(err, flag.ErrHelp):
		fmt.Fprintln(stderr, usage)
		return 2
	case err != nil:
		fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}

func runSnapshot(ctx context.Context, args []string, apiKey string, stdout io.Writer) error {
	flags := flag.NewFlagSet("snapshot", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	topologyPath := flags.String("topology", "../packages/topology/constants.json",
		"the topology constants, relative to provider/, where the root script runs this")
	endpoint := flags.String("endpoint", client.DefaultBaseURL, "the Onidel API base URL")
	if err := flags.Parse(args); err != nil || flags.NArg() != 1 || flags.Arg(0) == "" {
		return errUsage
	}
	name := flags.Arg(0)
	if apiKey == "" {
		return errors.New("onidel snapshot: ONIDEL_API_KEY is not set: run through op run --env-file=.env")
	}
	vmID, err := loadVMID(*topologyPath)
	if err != nil {
		return err
	}

	api := client.New(*endpoint, apiKey)
	desc := time.Now().UTC().Format("2006-01-02T15:04Z")
	if _, err := api.CreateSnapshot(ctx, vmID, onidelapi.NewSnapshot{Name: name, Desc: desc}); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "requested snapshot %s; it shows as available once Onidel finishes it\n", name)
	snapshots, err := api.ReadSnapshots(ctx)
	if err != nil {
		return err
	}
	for _, snapshot := range snapshots {
		fmt.Fprintf(stdout, "%s  %s  %s\n", snapshot.CreatedAt, snapshot.Status, snapshot.Name)
	}
	return nil
}

// loadVMID reads geoffcloud's VM ID from the topology constants.
func loadVMID(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("onidel snapshot: read the topology: %w", err)
	}
	var constants struct {
		VM struct {
			ID string `json:"id"`
		} `json:"vm"`
	}
	if err := json.Unmarshal(raw, &constants); err != nil {
		return "", fmt.Errorf("onidel snapshot: parse the topology %s: %w", path, err)
	}
	if constants.VM.ID == "" {
		return "", fmt.Errorf("onidel snapshot: the topology %s names no vm.id", path)
	}
	return constants.VM.ID, nil
}
