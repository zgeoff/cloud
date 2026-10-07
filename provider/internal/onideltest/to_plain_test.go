package onideltest_test

import (
	"testing"

	"github.com/pulumi/pulumi/sdk/v3/go/property"
	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestToPlainFlattensPropertiesToPlainValues(t *testing.T) {
	plain := onideltest.ToPlain(property.NewMap(map[string]property.Value{
		"name":    property.New("web"),
		"cpu":     property.New(2.0),
		"ipv6":    property.New(true),
		"sshKeys": property.New([]property.Value{property.New("key-1")}),
		"tags":    property.New(map[string]property.Value{"role": property.New("edge")}),
	}))

	assert.Equal(t, map[string]any{
		"name": "web", "cpu": 2.0, "ipv6": true, "sshKeys": []any{"key-1"},
		"tags": map[string]any{"role": "edge"},
	}, plain)
}

func TestToPlainReversesBuildProps(t *testing.T) {
	plain := map[string]any{"name": "web", "cpu": 2.0, "sshKeys": []any{"key-1"}}

	assert.Equal(t, plain, onideltest.ToPlain(onideltest.BuildProps(plain)))
}
