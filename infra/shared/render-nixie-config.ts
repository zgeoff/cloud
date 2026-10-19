import type { NixieImpConfig } from './build-nixie-imp-config.ts';

export function renderNixieConfig(text: string, imp: NixieImpConfig): string {
  const separator = text.endsWith('\n') ? '' : '\n';

  // JSON, which YAML reads as a flow mapping; the file holds no `imp` key of its own, so the
  // section never repeats one
  return `${text}${separator}imp: ${JSON.stringify(imp)}\n`;
}
