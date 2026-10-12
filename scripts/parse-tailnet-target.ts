import { isIP } from 'node:net';
import type { ProbeTarget } from './build-tcp-probe.ts';

// Tailscale's own resolver, which answers on every tailnet node
const defaultTarget = { host: '100.100.100.100', port: 53 };

// Parses the check's arguments: none for Tailscale's resolver, or one tailnet address and port,
// such as 100.64.0.5:443, or [fd7a:115c:a1e0::5]:443 for IPv6. Anything else is undefined.
export function parseTailnetTarget(args: readonly string[]): ProbeTarget | undefined {
  const [arg] = args;

  if (arg === undefined) {
    return defaultTarget;
  }

  const match = /^(?:\[(?<v6>[\da-f:]+)\]|(?<v4>[\d.]+)):(?<port>\d{1,5})$/iu.exec(arg);
  const host = match?.groups?.['v6'] ?? match?.groups?.['v4'] ?? '';
  const port = Number(match?.groups?.['port']);

  return args.length === 1 && isIP(host) !== 0 && port >= 1 && port <= 65_535
    ? { host, port }
    : undefined;
}
