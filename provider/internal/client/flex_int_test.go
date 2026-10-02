package client

import (
	"encoding/json"
	"testing"
)

func TestFlexIntDecodesNumbersAndStrings(t *testing.T) {
	for in, want := range map[string]FlexInt{`24`: 24, `"24"`: 24, `0`: 0, `"0"`: 0, `null`: 0, `""`: 0} {
		var got FlexInt
		if err := json.Unmarshal([]byte(in), &got); err != nil || got != want {
			t.Errorf("Unmarshal(%s) = %d, %v; want %d", in, got, err, want)
		}
	}
	var bad FlexInt
	if err := json.Unmarshal([]byte(`"x"`), &bad); err == nil {
		t.Error(`Unmarshal("x") succeeded; want an error`)
	}
}
