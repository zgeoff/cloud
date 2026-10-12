import { expect, test } from 'bun:test';
import type { ProbeAnswer } from './format-probe-answer.ts';
import { formatProbeAnswer } from './format-probe-answer.ts';

test.each([
  [
    'a connection',
    { target: { role: 'pod', host: '10.42.0.17', port: 8080 }, status: 0 },
    'pod 10.42.0.17:8080 connected',
  ],
  [
    'a refusal',
    { target: { role: 'node', host: '104.250.100.18', port: 10_250 }, status: 1 },
    'node 104.250.100.18:10250 blocked (exit 1)',
  ],
  [
    'a timeout to an IPv6 address',
    { target: { role: 'tailnet', host: 'fd7a:115c:a1e0::5', port: 443 }, status: 124 },
    'tailnet [fd7a:115c:a1e0::5]:443 blocked (exit 124)',
  ],
  [
    'a probe whose tool is missing as a failed probe, not a block',
    { target: { role: 'pod', host: '10.42.0.17', port: 8080 }, status: 127 },
    'pod 10.42.0.17:8080 probe failed (exit 127)',
  ],
  [
    'a probe that did not run',
    { target: { role: 'impd', host: '100.88.1.2', port: 443 }, status: null },
    'impd 100.88.1.2:443 probe did not run',
  ],
] satisfies [string, ProbeAnswer, string][])(
  'it formats %s',
  (_label: string, answer: ProbeAnswer, line: string) => {
    expect(formatProbeAnswer(answer)).toBe(line);
  },
);
