package onideltest

import presource "github.com/pulumi/pulumi/sdk/v3/go/common/resource"

// BuildURN returns the URN of a resource named name with type token in the test stack.
func BuildURN(token, name string) presource.URN {
	return presource.URN("urn:pulumi:test::test::" + token + "::" + name)
}
