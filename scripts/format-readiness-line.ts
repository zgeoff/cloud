export interface ReadinessLine {
  // missing is expected before the deploy, so only FAIL counts as a failure
  readonly status: 'ok' | 'missing' | 'FAIL';
  readonly text: string;
}

export function formatReadinessLine(line: Readonly<ReadinessLine>): string {
  return `${line.status.padEnd(8)} ${line.text}\n`;
}
