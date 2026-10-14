// Package onidelapi is the Onidel API client that oapi-codegen generates from
// provider/spec/onidel.yaml with provider/spec/onidel.overlay.yaml applied, for the
// operations oapi-codegen.yaml lists. The client package puts the retry, wait and error
// policy on top of it.
//
// Security: the API returns a VM's root password in plain text. The overlay removes the
// field, so no type here carries it and decoding drops it. Never log a response body.
package onidelapi

//go:generate go tool -modfile=../../tools.mod oapi-codegen -config oapi-codegen.yaml -o onidelapi.gen.go ../../spec/onidel.yaml
