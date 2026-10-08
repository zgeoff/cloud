package client

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strconv"
)

// FlexInt is an int that also decodes from a JSON string. Onidel is not consistent:
// a firewall rule's subnet_size is a number on GET and a string on POST.
type FlexInt int

// UnmarshalJSON accepts 24 and "24".
func (n *FlexInt) UnmarshalJSON(data []byte) error {
	data = bytes.Trim(data, `"`)
	if len(data) == 0 || string(data) == "null" {
		*n = 0
		return nil
	}
	v, err := strconv.Atoi(string(data))
	if err != nil {
		// The value stays out of the error: the caller wraps it into a message that
		// names the struct field, never the body.
		return &json.UnmarshalTypeError{Value: "non-integer value", Type: reflect.TypeFor[FlexInt]()}
	}
	*n = FlexInt(v)
	return nil
}
