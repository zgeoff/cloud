import { expect, test } from 'bun:test';
import type { ProbeTarget } from './build-tcp-probe.ts';
import { parseTailnetTarget } from './parse-tailnet-target.ts';

test('it has no default target, and asks for one when no argument is given', () => {
  expect(parseTailnetTarget([])).toStrictEqual({
    ok: false,
    error: 'give a tailnet address and port to probe, such as 100.69.47.33:443',
  });
});

test.each([
  ['an IPv4 address and port', '100.64.0.5:443', { host: '100.64.0.5', port: 443 }],
  [
    'a bracketed IPv6 address and port',
    '[fd7a:115c:a1e0::5]:22',
    { host: 'fd7a:115c:a1e0::5', port: 22 },
  ],
])('it parses %s', (_label: string, arg: string, target: ProbeTarget) => {
  expect(parseTailnetTarget([arg])).toStrictEqual({ ok: true, target });
});

test.each([
  ['an IPv4 address', '100.100.100.100:53'],
  ['a bracketed IPv6 address', '[fd7a:115c:a1e0::53]:53'],
])('it rejects %s on port 53, because imp answers DNS from its own proxy', (_label, arg) => {
  expect(parseTailnetTarget([arg])).toStrictEqual({
    ok: false,
    error: `cannot probe ${arg}: imp redirects a public sandbox's DNS connections to its own DNS proxy, so a probe of port 53 can connect even when the sandbox is isolated; pick a tailnet port that is not 53, such as 100.69.47.33:443`,
  });
});

test.each([
  ['a loopback IPv4 address', '127.0.0.1:22'],
  ['an IPv4 address just past the tailnet range', '100.128.0.1:443'],
  ['a loopback IPv6 address', '[::1]:22'],
  ['an IPv6 address outside the tailnet prefix', '[fd7a:115c:a1e1::5]:443'],
])('it rejects %s, because it is outside the tailnet', (_label, arg) => {
  expect(parseTailnetTarget([arg])).toStrictEqual({
    ok: false,
    error: `cannot probe ${arg}: the address is outside the tailnet's 100.64.0.0/10 and fd7a:115c:a1e0::/48, so the host and the sandbox can each reach a different listener on it and the probe would prove nothing`,
  });
});

test.each([
  ['a host name', ['geoffcloud:22']],
  ['an address with no port', ['100.64.0.5']],
  ['a port out of range', ['100.64.0.5:70000']],
  ['two targets', ['100.64.0.5:443', '100.64.0.6:443']],
])('it rejects %s', (_label: string, args: readonly string[]) => {
  expect(parseTailnetTarget(args)).toStrictEqual({
    ok: false,
    error: 'give one tailnet address and port, such as 100.69.47.33:443',
  });
});
