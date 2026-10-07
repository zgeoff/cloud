package onideltest

import (
	presource "github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/pulumi/pulumi/sdk/v3/go/property"
)

// ToPlain flattens a property map into plain Go values for assertions. Numbers come
// back as float64.
func ToPlain(m property.Map) map[string]any {
	return presource.ToResourcePropertyValue(property.New(m)).ObjectValue().Mappable()
}
