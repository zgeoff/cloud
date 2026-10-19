import { ExitError } from './exit-error.ts';

const unitMs: ReadonlyMap<string, number> = new Map([
  ['', 1000],
  ['s', 1000],
  ['m', 60_000],
  ['h', 3_600_000],
  ['d', 86_400_000],
]);

export function parseTimeoutDuration(text: string, name: string): number {
  // the duration format coreutils `timeout` reads
  const match = /^(?<amount>\d+(?:\.\d+)?)(?<unit>[smhd]?)$/u.exec(text);
  const amount = Number(match?.groups?.['amount'] ?? 'NaN');
  const durationMs = amount * (unitMs.get(match?.groups?.['unit'] ?? '') ?? 1000);

  // a duration of 0 disables coreutils `timeout`, so it is refused here instead
  if (!(durationMs > 0)) {
    throw new ExitError(2, `${name} holds '${text}', not a duration such as 45m`);
  }

  return durationMs;
}
