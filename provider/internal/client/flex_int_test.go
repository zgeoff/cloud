package client_test

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/client"
)

func TestFlexIntDecodesNumbersAndNumericStrings(t *testing.T) {
	rows := []struct {
		name  string
		input string
		want  client.FlexInt
	}{
		{"it decodes a number", `24`, 24},
		{"it decodes a numeric string", `"24"`, 24},
		{"it decodes zero", `0`, 0},
		{"it decodes a zero string", `"0"`, 0},
		{"it decodes null as zero", `null`, 0},
		{"it decodes an empty string as zero", `""`, 0},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			var got client.FlexInt

			err := json.Unmarshal([]byte(row.input), &got)

			require.NoError(t, err)
			assert.Equal(t, row.want, got)
		})
	}
}

func TestFlexIntRejectsANonNumericString(t *testing.T) {
	var got client.FlexInt

	err := json.Unmarshal([]byte(`"x"`), &got)

	var typeErr *json.UnmarshalTypeError
	require.ErrorAs(t, err, &typeErr)
	assert.Equal(t, &json.UnmarshalTypeError{Value: "subnet size"}, typeErr)
}
