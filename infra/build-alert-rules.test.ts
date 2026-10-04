import { describe, expect, test } from 'bun:test';
import { buildAlertRules } from './build-alert-rules.ts';

const rules = buildAlertRules().flatMap((group) => group.rules);

describe('buildAlertRules', () => {
  test('defines each alert once, with a severity and a summary', () => {
    expect(rules.map((rule) => rule.alert).toSorted()).toEqual([
      'CloudflaredNoConnections',
      'ContainerOOMKilled',
      'ImpHealthUnreachable',
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

describe('buildAlertRules for OOM kills', () => {
  test('alerts at once on a container restarted after an OOM kill', () => {
    const rule = getRule('ContainerOOMKilled');

    expect(rule).toMatchObject({ for: '0m', labels: { severity: 'warning' } });

    expect(rule.expr).toBe(
      'increase(kube_pod_container_status_restarts_total[10m]) > 0 and on (namespace, pod, container) kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1',
    );
  });
});

describe('buildAlertRules for imp over the tailnet', () => {
  test('alerts on a failed or missing imp health probe after 5 minutes', () => {
    expect(getRule('ImpHealthUnreachable')).toMatchObject({
      expr: 'probe_success{target="imp-health"} == 0 or absent(probe_success{target="imp-health"})',
      for: '5m',
      labels: { severity: 'critical' },
    });
  });
});

const geoffcloud = {
  name: 'geoffcloud',
  address: '100.69.47.33:8415',
  alertSeverity: 'critical',
} as const;

const homePC = {
  name: 'home-pc',
  address: '100.67.122.120:8415',
  alertSeverity: 'warning',
} as const;

describe('buildAlertRules with the atc gateway', () => {
  test('leaves out ATCDaemonUnreachable while the atc gateway is unset', () => {
    expect(rules.map((rule) => rule.alert)).not.toContain('ATCDaemonUnreachable');
    expect(buildAlertRules({ atcDaemons: undefined })).toEqual(buildAlertRules());
  });

  test("keeps geoffcloud's rule as it was with one daemon: target atc-daemon, its address", () => {
    const withGateway = buildAlertRules({ atcDaemons: [geoffcloud] });
    const all = withGateway.flatMap((group) => group.rules);
    const rule = all.find((r) => r.alert === 'ATCDaemonUnreachable');

    expect(all.filter((r) => r.alert !== 'ATCDaemonUnreachable')).toEqual(rules);

    expect(rule).toEqual({
      alert: 'ATCDaemonUnreachable',
      expr: 'probe_success{target="atc-daemon"} == 0 or absent(probe_success{target="atc-daemon"})',
      for: '5m',
      labels: { severity: 'critical' },
      annotations: {
        summary: "atc's daemon at 100.69.47.33:8415 is unreachable from the cluster.",
      },
    });
  });

  test('alerts on each daemon, its target labelled by its name', () => {
    const atcRules = buildAlertRules({ atcDaemons: [geoffcloud, homePC] })
      .flatMap((group) => group.rules)
      .filter((rule) => rule.alert === 'ATCDaemonUnreachable');

    expect(atcRules.map((rule) => rule.expr)).toEqual([
      'probe_success{target="atc-daemon"} == 0 or absent(probe_success{target="atc-daemon"})',
      'probe_success{target="atc-daemon-home-pc"} == 0 or absent(probe_success{target="atc-daemon-home-pc"})',
    ]);

    expect(atcRules.map((rule) => rule.labels.severity)).toEqual(['critical', 'warning']);

    expect(atcRules[1]?.annotations.summary).toBe(
      "atc's daemon at 100.67.122.120:8415 is unreachable from the cluster.",
    );
  });
});

function getRule(name: string): (typeof rules)[number] {
  const rule = rules.find((candidate) => candidate.alert === name);

  if (rule === undefined) {
    throw new Error(`no rule ${name}`);
  }

  return rule;
}
