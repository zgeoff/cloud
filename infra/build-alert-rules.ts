interface AlertRule {
  readonly alert: string;
  readonly expr: string;
  readonly for: string;
  readonly labels: { readonly severity: 'critical' | 'warning' };
  readonly annotations: { readonly summary: string };
}

interface AlertRuleGroup {
  readonly name: string;
  readonly rules: readonly AlertRule[];
}

interface AlertRuleInputs {
  // the daemon's host:port, set only while the stack config sets atcGateway
  readonly atcDaemonAddress?: string | undefined;
}

// geoff.cloud's own alerts (#29), as Prometheus rule groups: the `spec.groups` of a
// PrometheusRule, and also a valid rule file for `promtool check rules`.
//
// A missing metric must alert, never read as healthy: each check that rests on one
// metric also fires when that metric is absent.
export function buildAlertRules(inputs: AlertRuleInputs = {}): readonly AlertRuleGroup[] {
  const atcRules =
    inputs.atcDaemonAddress === undefined ? [] : [buildATCDaemonRule(inputs.atcDaemonAddress)];

  return [
    { name: 'geoff-cloud', rules: [...impdRules, targetDownRule, cloudflaredRule, ...atcRules] },
  ];
}

// impd's loopback probe, written every minute by a host timer to node-exporter's
// textfile collector (nixos/modules/impd-local-health.nix)
const impdRules: readonly AlertRule[] = [
  {
    alert: 'ImpdLocalHealthDown',
    expr: 'impd_local_health_up == 0',
    for: '2m',
    labels: { severity: 'critical' },
    annotations: { summary: 'impd fails its loopback health check on geoffcloud.' },
  },
  {
    // five missed probes, or no probe metric at all (the timer, the textfile or
    // node-exporter is gone)
    alert: 'ImpdLocalHealthStale',
    expr: 'time() - impd_local_health_last_check_timestamp_seconds > 300 or absent(impd_local_health_up)',
    for: '2m',
    labels: { severity: 'warning' },
    annotations: { summary: 'impd health probe has not reported for over 5 minutes.' },
  },
];

// per target, so one dead exporter is named; replaces the chart's ratio-based TargetDown
const targetDownRule: AlertRule = {
  alert: 'TargetDown',
  expr: 'up == 0',
  for: '5m',
  labels: { severity: 'warning' },
  annotations: { summary: 'Scrape target {{ $labels.job }} {{ $labels.instance }} is down.' },
};

// Summed over both cloudflared pods: the tunnel serves while either pod holds a
// connection, so only zero across both is an outage. One pod down shows as TargetDown.
// A dead exporter must not look healthy: no series, or no cloudflared target up, fires too.
const cloudflaredRule: AlertRule = {
  alert: 'CloudflaredNoConnections',
  expr: [
    'sum(cloudflared_tunnel_ha_connections) == 0',
    'absent(cloudflared_tunnel_ha_connections)',
    'absent(up{namespace="ingress", pod=~"cloudflared-.*"} == 1)',
  ].join(' or '),
  for: '5m',
  labels: { severity: 'critical' },
  annotations: { summary: 'cloudflared holds no tunnel connection to Cloudflare.' },
};

// the probe target name of atc's daemon, which the probe's ServiceMonitor stamps on
// its series as the `target` label (create-atc-daemon-probe.ts)
export const atcDaemonProbeTarget = 'atc-daemon';

// The blackbox exporter's TCP connect to atc's daemon fails, or reports nothing: no
// gateway call can reach the daemon then. Only while the gateway is configured, so an
// unset gateway, which has no probe, fires nothing. The address is in the summary
// itself: the absent() series carries no instance label.
function buildATCDaemonRule(address: string): AlertRule {
  const series = `probe_success{target="${atcDaemonProbeTarget}"}`;

  return {
    alert: 'ATCDaemonUnreachable',
    expr: `${series} == 0 or absent(${series})`,
    for: '5m',
    labels: { severity: 'critical' },
    annotations: { summary: `atc's daemon at ${address} is unreachable from the cluster.` },
  };
}
