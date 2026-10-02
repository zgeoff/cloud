package client

import (
	"bytes"
	"encoding/json"
)

// FlexString is a string that also decodes from a JSON number. Onidel is not
// consistent: a VM's firewall_group_id is a string on some reads and a number on others.
type FlexString string

// UnmarshalJSON accepts "12", 12 and null (as "").
func (s *FlexString) UnmarshalJSON(data []byte) error {
	if string(data) == "null" {
		*s = ""
		return nil
	}
	if bytes.HasPrefix(data, []byte(`"`)) {
		var v string
		if err := json.Unmarshal(data, &v); err != nil {
			return err
		}
		*s = FlexString(v)
		return nil
	}
	var n json.Number
	if err := json.Unmarshal(data, &n); err != nil {
		return err
	}
	*s = FlexString(n.String())
	return nil
}
