import { describe, expect, test } from 'bun:test';
import { toATCDaemonProbeTarget } from './to-atc-daemon-probe-target.ts';

describe('toATCDaemonProbeTarget', () => {
  test("keeps geoffcloud's target as it was and names every other by its daemon", () => {
    expect(toATCDaemonProbeTarget('geoffcloud')).toBe('atc-daemon');
    expect(toATCDaemonProbeTarget('home-pc')).toBe('atc-daemon-home-pc');
  });
});
