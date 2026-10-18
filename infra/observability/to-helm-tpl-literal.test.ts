import { expect, test } from 'bun:test';
import { toHelmTplLiteral } from './to-helm-tpl-literal.ts';

test('it turns each opening delimiter into an action that prints it, and leaves the rest of the text alone', () => {
  expect(
    toHelmTplLiteral(
      String.raw`template = "{{ if eq .kind \"other\" }}other{{- else }}{{ .outcome }}{{ end }}"`,
    ),
  ).toBe(
    String.raw`template = "{{ "{{" }} if eq .kind \"other\" }}other{{ "{{" }}- else }}{{ "{{" }} .outcome }}{{ "{{" }} end }}"`,
  );
});

test('it leaves text with no opening delimiter unchanged', () => {
  expect(toHelmTplLiteral('stage.drop {\n  older_than = "1h"\n}\n')).toBe(
    'stage.drop {\n  older_than = "1h"\n}\n',
  );
});
