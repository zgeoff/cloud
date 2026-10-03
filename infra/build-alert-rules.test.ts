import { describe, expect, test } from 'bun:test';
import { buildAlertRules } from './build-alert-rules.ts';

const rules = buildAlertRules().flatMap((group) => group.rules);

describe('buildAlertRules', () => {
  test('defines each alert once, with a severity and a summary', () => {
    expect(rules.map((rule) => rule.alert).toSorted()).toEqual([
      'CloudflaredNoConnections',
      'ImpdLocalHealthDown',
      'ImpdLocalHealthStale',
      'TargetDown',
    ]);

    for (const rule of rules) {
      expect(['critical', 'warning']).toContain(rule.labels.severity);
      expect(rule.annotations.summary).not.toBe('');
    }
  });

  test('alerts on impd failing its probe after 2 minutes', () => {
    expect(getRule('ImpdLocalHealthDown')).toMatchObject({
      expr: 'impd_local_health_up == 0',
      for: '2m',
    });
  });

  test('alerts on a stale or missing impd probe metric', () => {
    const rule = getRule('ImpdLocalHealthStale');

    expect(rule.expr).toContain('time() - impd_local_health_last_check_timestamp_seconds > 300');
    expect(rule.expr).toContain('or absent(impd_local_health_up)');
  });

  test('alerts on any scrape target down for 5 minutes', () => {
    expect(getRule('TargetDown')).toMatchObject({ expr: 'up == 0', for: '5m' });
  });

  test('alerts on no tunnel connections, a missing metric, or no cloudflared target up', () => {
    const rule = getRule('CloudflaredNoConnections');

    expect(rule.for).toBe('5m');

    expect(rule.expr.split(' or ')).toEqual([
      'sum(cloudflared_tunnel_ha_connections) == 0',
      'absent(cloudflared_tunnel_ha_connections)',
      'absent(up{namespace="ingress", pod=~"cloudflared-.*"} == 1)',
    ]);
  });
});

function getRule(name: string): (typeof rules)[number] {
  const rule = rules.find((candidate) => candidate.alert === name);

  if (rule === undefined) {
    throw new Error(`no rule ${name}`);
  }

  return rule;
}
