import { expect, test } from 'bun:test';
import type { ProbeTarget } from './build-tcp-probe.ts';
import { parseTailnetTarget } from './parse-tailnet-target.ts';

test('it targets Tailscale’s resolver when no argument is given', () => {
  expect(parseTailnetTarget([])).toStrictEqual({ host: '100.100.100.100', port: 53 });
});

test.each([
  ['an IPv4 address and port', '100.64.0.5:443', { host: '100.64.0.5', port: 443 }],
  [
    'a bracketed IPv6 address and port',
    '[fd7a:115c:a1e0::5]:22',
    { host: 'fd7a:115c:a1e0::5', port: 22 },
  ],
])('it parses %s', (_label: string, arg: string, target: ProbeTarget) => {
  expect(parseTailnetTarget([arg])).toStrictEqual(target);
});

test.each([
  ['a host name', ['geoffcloud:22']],
  ['an address with no port', ['100.64.0.5']],
  ['a port out of range', ['100.64.0.5:70000']],
  ['two targets', ['100.64.0.5:443', '100.64.0.6:443']],
])('it rejects %s', (_label: string, args: readonly string[]) => {
  expect(parseTailnetTarget(args)).toBeUndefined();
});
