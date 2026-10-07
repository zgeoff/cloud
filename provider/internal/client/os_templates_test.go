package client_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
)

func TestReadOSTemplatesListsTheTemplates(t *testing.T) {
	ctx := setupTest(t)

	templates, err := ctx.client.ReadOSTemplates(t.Context())

	require.NoError(t, err)
	assert.Equal(t, []client.OSTemplate{
		{ID: 3, Name: "Ubuntu 24.04 LTS x64", Family: "Ubuntu"},
		{ID: 24, Name: "Ubuntu 26.04 LTS x64", Family: "Ubuntu"},
	}, templates)
}
