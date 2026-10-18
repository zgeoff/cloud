// Text that Helm's tpl gives back unchanged: each `{{` becomes an action that prints `{{`, so the
// rest of a Go template in the text, such as an Alloy stage.template, stays plain text. A `}}`
// outside an action is already plain text to tpl.
export function toHelmTplLiteral(text: string): string {
  return text.replaceAll('{{', '{{ "{{" }}');
}
