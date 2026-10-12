import { isIP } from 'node:net';
import type { ProbeTarget } from './build-tcp-probe.ts';

export type TailnetTargetResult =
  | { readonly ok: true; readonly target: ProbeTarget }
  | { readonly ok: false; readonly error: string };

// imp redirects a public sandbox's DNS connections to its own DNS proxy, so a probe of port 53 can
// connect however well the sandbox is isolated, and the check would fail a correct deployment
const dnsPort = 53;

// Parses the check's arguments: exactly one tailnet address and port, such as 100.69.47.33:443, or
// [fd7a:115c:a1e0::5]:443 for IPv6. It has no default, so the caller always names a listener that
// is not on port 53.
export function parseTailnetTarget(args: readonly string[]): TailnetTargetResult {
  const [arg] = args;

  if (arg === undefined) {
    return {
      ok: false,
      error: 'give a tailnet address and port to probe, such as 100.69.47.33:443',
    };
  }

  const target = args.length === 1 ? findAddress(arg) : undefined;

  if (target === undefined) {
    return { ok: false, error: 'give one tailnet address and port, such as 100.69.47.33:443' };
  }

  if (target.port === dnsPort) {
    return {
      ok: false,
      error: `cannot probe ${arg}: imp redirects a public sandbox's DNS connections to its own DNS proxy, so a probe of port 53 can connect even when the sandbox is isolated; pick a tailnet port that is not 53, such as 100.69.47.33:443`,
    };
  }

  return { ok: true, target };
}

// an IP address and port, with an IPv6 address in brackets; undefined for anything else
function findAddress(arg: string): ProbeTarget | undefined {
  const match = /^(?:\[(?<v6>[\da-f:]+)\]|(?<v4>[\d.]+)):(?<port>\d{1,5})$/iu.exec(arg);
  const host = match?.groups?.['v6'] ?? match?.groups?.['v4'] ?? '';
  const port = Number(match?.groups?.['port']);

  return isIP(host) !== 0 && port >= 1 && port <= 65_535 ? { host, port } : undefined;
}
