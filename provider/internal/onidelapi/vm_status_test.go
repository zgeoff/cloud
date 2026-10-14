package onidelapi_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

func TestVMStatusListIsTheOverlaidSpecEnum(t *testing.T) {
	spec, err := onidelapi.GetSpec()
	require.NoError(t, err)

	assert.Equal(t, []any{
		"building", "active", "suspended", "awaiting_payment", "taking_snaphot", "restoring",
		"terminating", "migrating", "taking_snapshot", "terminated", "deleted", "destroyed",
	}, spec.Components.Schemas["VM"].Value.Properties["status"].Value.Enum)
}

func TestVMStatusSaysWhetherAVMSettlesOrIsGone(t *testing.T) {
	rows := []struct {
		name     string
		status   onidelapi.VMStatus
		settling bool
		gone     bool
	}{
		{"it treats active as neither", onidelapi.VMStatusActive, false, false},
		{"it waits on building", onidelapi.VMStatusBuilding, true, false},
		{"it waits on restoring", onidelapi.VMStatusRestoring, true, false},
		{"it waits on migrating", onidelapi.VMStatusMigrating, true, false},
		{"it waits on the spec's taking_snaphot", onidelapi.VMStatusTakingSnaphot, true, false},
		{"it waits on taking_snapshot", onidelapi.VMStatusTakingSnapshot, true, false},
		{"it treats suspended as neither", onidelapi.VMStatusSuspended, false, false},
		{"it treats awaiting_payment as neither", onidelapi.VMStatusAwaitingPayment, false, false},
		{"it treats terminating as neither", onidelapi.VMStatusTerminating, false, false},
		{"it treats terminated as gone", onidelapi.VMStatusTerminated, false, true},
		{"it treats deleted as gone", onidelapi.VMStatusDeleted, false, true},
		{"it treats destroyed as gone", onidelapi.VMStatusDestroyed, false, true},
		{"it treats an unknown status as neither", onidelapi.VMStatus("rebooting"), false, false},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			assert.Equal(t, row.settling, row.status.IsSettling())
			assert.Equal(t, row.gone, row.status.IsGone())
		})
	}
}
