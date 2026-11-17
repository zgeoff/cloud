import type { NixieImpConfig } from './build-nixie-imp-config.ts';
import type { NixieSpendStopConfig } from './build-nixie-spend-stop-config.ts';

export interface NixieConfigSections {
  readonly imp: NixieImpConfig;
  readonly spendStop: NixieSpendStopConfig;
}

export function renderNixieConfig(text: string, sections: NixieConfigSections): string {
  const separator = text.endsWith('\n') ? '' : '\n';

  // JSON, which YAML reads as a flow mapping; the file holds neither key of its own, so neither
  // section repeats one
  return `${text}${separator}imp: ${JSON.stringify(sections.imp)}\nspendStop: ${JSON.stringify(sections.spendStop)}\n`;
}
