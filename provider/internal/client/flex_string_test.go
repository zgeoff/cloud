package client_test

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
)

func TestFlexStringDecodesStringsNumbersAndNull(t *testing.T) {
	rows := []struct {
		name  string
		input string
		want  client.FlexString
	}{
		{"it decodes a numeric string", `"12"`, "12"},
		{"it decodes a number as its digits", `12`, "12"},
		{"it decodes a plain string", `"abc"`, "abc"},
		{"it decodes null as empty", `null`, ""},
		{"it decodes an empty string", `""`, ""},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			var got client.FlexString

			err := json.Unmarshal([]byte(row.input), &got)

			require.NoError(t, err)
			assert.Equal(t, row.want, got)
		})
	}
}

func TestFlexStringRejectsABoolean(t *testing.T) {
	var got client.FlexString

	err := json.Unmarshal([]byte(`true`), &got)

	assert.EqualError(t, err, "json: cannot unmarshal bool into Go value of type json.Number")
}
