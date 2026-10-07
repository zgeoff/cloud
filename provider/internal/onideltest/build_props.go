package onideltest

import (
	presource "github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/pulumi/pulumi/sdk/v3/go/property"
)

// BuildProps turns a plain Go map into a property map. Numbers must be float64 or int.
func BuildProps(m map[string]any) property.Map {
	pm := presource.NewPropertyMapFromMap(m)
	return presource.FromResourcePropertyValue(presource.NewObjectProperty(pm)).AsMap()
}
