// Package clienttest holds the factories for the client package's request types. They live
// apart from onideltest because client's internal test imports onideltest, so an onideltest
// that imported client would form an import cycle.
package clienttest
