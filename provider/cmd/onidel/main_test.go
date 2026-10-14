package main_test

import (
	"bytes"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

// These tests run the built binary against the stub API on loopback: no case reaches
// Onidel. Each run's exit code, stdout and stderr are compared together.

// setupTest builds the onidel binary into a temporary directory and starts the stub API
// it talks to. Each test writes its own topology file and stores its own VM.
func setupTest(t *testing.T) struct {
	api *onideltest.StubOnidelAPI
	bin string
	dir string
} {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "onidel")
	out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput()
	require.NoError(t, err, string(out))
	return struct {
		api *onideltest.StubOnidelAPI
		bin string
		dir string
	}{api: onideltest.StartStubOnidelAPI(t), bin: bin, dir: dir}
}

func TestSnapshotSnapshotsTheTopologysVMAndListsTheSnapshots(t *testing.T) {
	ctx := setupTest(t)
	topology := filepath.Join(ctx.dir, "constants.json")
	require.NoError(t, os.WriteFile(topology, []byte(`{"vm":{"id":"9d1c7c2e-6f0a-4f43-9a51-3b8e2f6d1a77"}}`), 0o600))
	ctx.api.SetVM(map[string]any{
		"id": "9d1c7c2e-6f0a-4f43-9a51-3b8e2f6d1a77", "name": "geoffcloud", "disk": 240, "status": "active",
		"password": "fixture-root-pw-do-not-leak",
	})
	cmd := exec.Command(ctx.bin, "snapshot", "-topology", topology, "-endpoint", ctx.api.URL, "pre-imp-1.1")
	cmd.Env = []string{"ONIDEL_API_KEY=" + onideltest.APIKey}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	before := time.Now().UTC().Truncate(time.Minute)

	err := cmd.Run()

	after := time.Now().UTC()
	assert.Equal(t, []any{0, "requested snapshot pre-imp-1.1; it shows as available once Onidel finishes it\n" +
		"2026-10-02T06:00:00Z  pending  pre-imp-1.1\n", ""}, []any{cmd.ProcessState.ExitCode(), stdout.String(), stderr.String()})
	require.NoError(t, err)
	requests := ctx.api.GetRequests()
	require.Len(t, requests, 2)
	desc, ok := requests[0].Body["desc"].(string)
	require.True(t, ok)
	stamp, err := time.Parse("2006-01-02T15:04Z", desc)
	require.NoError(t, err)
	assert.WithinRange(t, stamp, before, after)
	assert.Equal(t, []onideltest.Request{
		{Method: "POST", Path: "/vm/9d1c7c2e-6f0a-4f43-9a51-3b8e2f6d1a77/snapshot", Body: map[string]any{"name": "pre-imp-1.1", "desc": desc}},
		{Method: "GET", Path: "/snapshots"},
	}, requests)
	assert.Equal(t, []map[string]any{{
		"id": "00000000-0000-4000-8000-000000000001", "created_at": "2026-10-02T06:00:00Z", "name": "pre-imp-1.1",
		"desc": desc, "size": 240, "status": "pending",
	}}, ctx.api.GetSnapshots())
}

func TestSnapshotStopsWithItsUsageOnABadCommandLine(t *testing.T) {
	rows := []struct {
		name string
		args []string
	}{
		{"it stops without an action", []string{}},
		{"it stops on an unknown action", []string{"restore", "pre-imp-1.1"}},
		{"it stops without a name", []string{"snapshot"}},
		{"it stops on an empty name", []string{"snapshot", ""}},
		{"it stops on two names", []string{"snapshot", "a", "b"}},
		{"it stops on an unknown flag", []string{"snapshot", "-vm", "x", "pre-imp-1.1"}},
		{"it stops on a request for help", []string{"snapshot", "-h"}},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			cmd := exec.Command(ctx.bin, row.args...)
			cmd.Env = []string{"ONIDEL_API_KEY=" + onideltest.APIKey}
			var stdout, stderr bytes.Buffer
			cmd.Stdout, cmd.Stderr = &stdout, &stderr

			_ = cmd.Run()

			assert.Equal(t, []any{2, "", "usage: onidel snapshot [-topology path] [-endpoint url] <name>, such as pre-imp-1.1\n"},
				[]any{cmd.ProcessState.ExitCode(), stdout.String(), stderr.String()})
			assert.Equal(t, []onideltest.Request(nil), ctx.api.GetRequests())
		})
	}
}

func TestSnapshotFailsWithoutAnAPIKey(t *testing.T) {
	ctx := setupTest(t)
	topology := filepath.Join(ctx.dir, "constants.json")
	require.NoError(t, os.WriteFile(topology, []byte(`{"vm":{"id":"9d1c7c2e-6f0a-4f43-9a51-3b8e2f6d1a77"}}`), 0o600))
	cmd := exec.Command(ctx.bin, "snapshot", "-topology", topology, "-endpoint", ctx.api.URL, "pre-imp-1.1")
	cmd.Env = []string{}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr

	_ = cmd.Run()

	assert.Equal(t, []any{1, "", "onidel snapshot: ONIDEL_API_KEY is not set: run through op run --env-file=.env\n"},
		[]any{cmd.ProcessState.ExitCode(), stdout.String(), stderr.String()})
	assert.Equal(t, []onideltest.Request(nil), ctx.api.GetRequests())
}

func TestSnapshotFailsOnATopologyWithoutAVMID(t *testing.T) {
	rows := []struct {
		name     string
		contents string
		want     string
	}{
		{"it fails on a topology with no vm", `{"tailnet":{}}`, "onidel snapshot: the topology %s names no vm.id\n"},
		{"it fails on a topology that is not JSON", `vm: x`,
			"onidel snapshot: parse the topology %s: invalid character 'v' looking for beginning of value\n"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			ctx := setupTest(t)
			topology := filepath.Join(ctx.dir, "constants.json")
			require.NoError(t, os.WriteFile(topology, []byte(row.contents), 0o600))
			cmd := exec.Command(ctx.bin, "snapshot", "-topology", topology, "-endpoint", ctx.api.URL, "pre-imp-1.1")
			cmd.Env = []string{"ONIDEL_API_KEY=" + onideltest.APIKey}
			var stdout, stderr bytes.Buffer
			cmd.Stdout, cmd.Stderr = &stdout, &stderr

			_ = cmd.Run()

			assert.Equal(t, []any{1, "", fmt.Sprintf(row.want, topology)}, []any{cmd.ProcessState.ExitCode(), stdout.String(), stderr.String()})
			assert.Equal(t, []onideltest.Request(nil), ctx.api.GetRequests())
		})
	}
}

func TestSnapshotFailsOnATopologyItCannotRead(t *testing.T) {
	ctx := setupTest(t)
	topology := filepath.Join(ctx.dir, "missing.json")
	cmd := exec.Command(ctx.bin, "snapshot", "-topology", topology, "-endpoint", ctx.api.URL, "pre-imp-1.1")
	cmd.Env = []string{"ONIDEL_API_KEY=" + onideltest.APIKey}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr

	_ = cmd.Run()

	assert.Equal(t, []any{1, "", "onidel snapshot: read the topology: open " + topology + ": no such file or directory\n"},
		[]any{cmd.ProcessState.ExitCode(), stdout.String(), stderr.String()})
	assert.Equal(t, []onideltest.Request(nil), ctx.api.GetRequests())
}

func TestSnapshotFailsWhenOnidelRefusesTheSnapshot(t *testing.T) {
	ctx := setupTest(t)
	topology := filepath.Join(ctx.dir, "constants.json")
	require.NoError(t, os.WriteFile(topology, []byte(`{"vm":{"id":"9d1c7c2e-6f0a-4f43-9a51-3b8e2f6d1a77"}}`), 0o600))
	ctx.api.SetVM(map[string]any{"id": "9d1c7c2e-6f0a-4f43-9a51-3b8e2f6d1a77", "status": "active"})
	// The spec answers 403 when the snapshot limit is reached or a volume is attached.
	ctx.api.RegisterResponse("POST /vm/{id}/snapshot", http.StatusForbidden, `{"err":"SNAPSHOT_LIMIT_REACHED"}`, 1)
	cmd := exec.Command(ctx.bin, "snapshot", "-topology", topology, "-endpoint", ctx.api.URL, "pre-imp-1.1")
	cmd.Env = []string{"ONIDEL_API_KEY=" + onideltest.APIKey}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr

	_ = cmd.Run()

	assert.Equal(t, []any{1, "", "onidel: POST /vm/9d1c7c2e-6f0a-4f43-9a51-3b8e2f6d1a77/snapshot: HTTP 403: SNAPSHOT_LIMIT_REACHED\n"},
		[]any{cmd.ProcessState.ExitCode(), stdout.String(), stderr.String()})
	assert.Equal(t, []map[string]any{}, ctx.api.GetSnapshots())
}

func TestSnapshotFailsWithAWrongAPIKey(t *testing.T) {
	ctx := setupTest(t)
	topology := filepath.Join(ctx.dir, "constants.json")
	require.NoError(t, os.WriteFile(topology, []byte(`{"vm":{"id":"9d1c7c2e-6f0a-4f43-9a51-3b8e2f6d1a77"}}`), 0o600))
	ctx.api.SetVM(map[string]any{"id": "9d1c7c2e-6f0a-4f43-9a51-3b8e2f6d1a77", "status": "active"})
	cmd := exec.Command(ctx.bin, "snapshot", "-topology", topology, "-endpoint", ctx.api.URL, "pre-imp-1.1")
	cmd.Env = []string{"ONIDEL_API_KEY=revoked-key"}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr

	_ = cmd.Run()

	assert.Equal(t, []any{1, "", "onidel: POST /vm/9d1c7c2e-6f0a-4f43-9a51-3b8e2f6d1a77/snapshot: HTTP 401\n"},
		[]any{cmd.ProcessState.ExitCode(), stdout.String(), stderr.String()})
	assert.Equal(t, []map[string]any{}, ctx.api.GetSnapshots())
}

func TestSnapshotReportsAListingThatFailsAfterTheSnapshotStarted(t *testing.T) {
	ctx := setupTest(t)
	topology := filepath.Join(ctx.dir, "constants.json")
	require.NoError(t, os.WriteFile(topology, []byte(`{"vm":{"id":"9d1c7c2e-6f0a-4f43-9a51-3b8e2f6d1a77"}}`), 0o600))
	ctx.api.SetVM(map[string]any{"id": "9d1c7c2e-6f0a-4f43-9a51-3b8e2f6d1a77", "disk": 240, "status": "active"})
	ctx.api.RegisterResponse("GET /snapshots", http.StatusInternalServerError, "", 1)
	cmd := exec.Command(ctx.bin, "snapshot", "-topology", topology, "-endpoint", ctx.api.URL, "pre-imp-1.1")
	cmd.Env = []string{"ONIDEL_API_KEY=" + onideltest.APIKey}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr

	_ = cmd.Run()

	assert.Equal(t, []any{1, "requested snapshot pre-imp-1.1; it shows as available once Onidel finishes it\n", "onidel: GET /snapshots: HTTP 500\n"},
		[]any{cmd.ProcessState.ExitCode(), stdout.String(), stderr.String()})
	assert.Len(t, ctx.api.GetSnapshots(), 1)
}
