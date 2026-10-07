package onideltest_test

import (
	"testing"

	presource "github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/stretchr/testify/assert"

	"github.com/zgeoff/cloud/provider/internal/onideltest"
)

func TestBuildURNNamesAResourceInTheTestStack(t *testing.T) {
	assert.Equal(t, presource.URN("urn:pulumi:test::test::onidel:index:Vm::web"), onideltest.BuildURN("onidel:index:Vm", "web"))
}
