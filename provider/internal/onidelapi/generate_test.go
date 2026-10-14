package onidelapi_test

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

// The API returns a VM's root password in plain text. Every type the client and the
// provider decode into comes from this package, so no struct here may have a field that
// could hold it: one named for it, one that decodes it, or a catch-all for unknown keys.
func TestNoGeneratedTypeHasAPasswordField(t *testing.T) {
	entries, err := os.ReadDir(".")
	require.NoError(t, err)
	var exposed, files []string
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".go") || strings.HasSuffix(entry.Name(), "_test.go") {
			continue
		}
		files = append(files, entry.Name())
		file, err := parser.ParseFile(token.NewFileSet(), entry.Name(), nil, parser.SkipObjectResolution)
		require.NoError(t, err)
		ast.Inspect(file, func(node ast.Node) bool {
			spec, ok := node.(*ast.TypeSpec)
			if !ok {
				return true
			}
			ast.Inspect(spec.Type, func(node ast.Node) bool {
				field, ok := node.(*ast.Field)
				if !ok {
					return true
				}
				var key string
				if field.Tag != nil {
					tag, _ := strconv.Unquote(field.Tag.Value)
					key = strings.ToLower(strings.Split(reflect.StructTag(tag).Get("json"), ",")[0])
				}
				for _, name := range field.Names {
					lower := strings.ToLower(name.Name)
					if strings.Contains(lower, "password") || strings.Contains(key, "password") || lower == "additionalproperties" {
						exposed = append(exposed, spec.Name.Name+"."+name.Name)
					}
				}
				return true
			})
			return false
		})
	}

	require.Contains(t, files, "onidelapi.gen.go")
	assert.Empty(t, exposed)
}

func TestEmbeddedSpecHasNoPasswordProperty(t *testing.T) {
	spec, err := onidelapi.GetSpec()
	require.NoError(t, err)
	raw, err := json.Marshal(spec)
	require.NoError(t, err)
	var doc any
	require.NoError(t, json.Unmarshal(raw, &doc))
	var exposed []string
	var walk func(path string, node any)
	walk = func(path string, node any) {
		switch value := node.(type) {
		case map[string]any:
			if props, ok := value["properties"].(map[string]any); ok {
				for name := range props {
					if strings.Contains(strings.ToLower(name), "password") {
						exposed = append(exposed, path+".properties."+name)
					}
				}
			}
			for key, child := range value {
				walk(path+"."+key, child)
			}
		case []any:
			for i, child := range value {
				walk(path+"["+strconv.Itoa(i)+"]", child)
			}
		}
	}

	walk("$", doc)

	require.Contains(t, string(raw), `"VM"`)
	assert.Empty(t, exposed)
}
