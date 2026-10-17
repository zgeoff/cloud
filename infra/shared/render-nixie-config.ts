import type { NixieImpConfig } from './build-nixie-imp-config.ts';

// deploy/nixie/config.yaml with its `imp` section added as the last key, written as JSON, which
// YAML reads as a flow mapping; the file holds no `imp` key of its own, so the section never
// repeats one
export function renderNixieConfig(text: string, imp: NixieImpConfig): string {
  const separator = text.endsWith('\n') ? '' : '\n';

  return `${text}${separator}imp: ${JSON.stringify(imp)}\n`;
}
