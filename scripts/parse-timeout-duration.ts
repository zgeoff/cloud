import { ExitError } from './exit-error.ts';

const unitMs: Readonly<Record<string, number>> = {
  '': 1000,
  s: 1000,
  m: 60_000,
  h: 3_600_000,
  d: 86_400_000,
};

// Parses a duration as coreutils `timeout` reads one: a number, whole or decimal, and an optional
// unit of s, m, h or d, where no unit means seconds. Returns milliseconds. A duration of 0
// disables the timeout there, so it is refused here instead.
export function parseTimeoutDuration(text: string, name: string): number {
  const match = /^(?<amount>\d+(?:\.\d+)?)(?<unit>[smhd]?)$/u.exec(text);
  const amount = Number(match?.groups?.amount ?? 'NaN');
  const ms = amount * (unitMs[match?.groups?.unit ?? ''] ?? 1000);

  if (!(ms > 0)) {
    throw new ExitError(2, `${name} holds '${text}', not a duration such as 45m`);
  }

  return ms;
}
