import { expect, test } from 'bun:test';
import { toATCDaemonProbeTarget } from './to-atc-daemon-probe-target.ts';

test('it keeps the plain atc-daemon target for geoffcloud', () => {
  expect(toATCDaemonProbeTarget('geoffcloud')).toBe('atc-daemon');
});

test('it names the target of any other daemon after the daemon', () => {
  expect(toATCDaemonProbeTarget('home-pc')).toBe('atc-daemon-home-pc');
});
