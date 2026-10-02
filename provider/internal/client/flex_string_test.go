package client

import (
	"encoding/json"
	"testing"
)

func TestFlexStringDecodesStringsNumbersAndNull(t *testing.T) {
	for in, want := range map[string]FlexString{`"12"`: "12", `12`: "12", `"abc"`: "abc", `null`: "", `""`: ""} {
		var got FlexString
		if err := json.Unmarshal([]byte(in), &got); err != nil || got != want {
			t.Errorf("Unmarshal(%s) = %q, %v; want %q", in, got, err, want)
		}
	}
	var bad FlexString
	if err := json.Unmarshal([]byte(`true`), &bad); err == nil {
		t.Error("Unmarshal(true) succeeded; want an error")
	}
}
