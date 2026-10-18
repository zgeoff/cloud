import { atcSecurityEvents } from './atc-security-events.ts';
import type { AlertRule, AlertRuleGroup } from './build-alert-rules.ts';

// how far back each rule counts events, and so how long an alert fires after its last event
const window = '5m';

// The count of events in the window, in printf form for an annotation
const count = '{{ $value | printf "%.0f" }}';

// Alerts on atc's sign-in events from Alloy's counters, one alert per category, each summing its
// events per label set into one alert whose value is the count. No rule has an absent() branch,
// because no event is the normal state; TargetDown covers Alloy itself.
export function buildATCSignInRules(): AlertRuleGroup {
  return {
    name: 'atc-sign-in',
    rules: [
      {
        alert: 'ATCGatewaySignInStarted',
        expr: buildEventCount('kind="authorize_started", outcome="accepted"', ['route']),
        for: '0m',
        labels: { severity: 'notice' },
        annotations: {
          summary: `The atc gateway accepted ${count} sign-in start(s) in the last ${window}.`,
        },
      },
      {
        alert: 'ATCGatewaySignInRateLimited',
        expr: buildEventCount('kind="authorize_started", outcome="rejected"', ['reason']),
        for: '0m',
        labels: { severity: 'warning' },
        annotations: {
          summary: `The atc gateway refused ${count} sign-in start(s) at its rate limit in the last ${window}. The limit counts every client together, so the alert names no source.`,
        },
      },
      {
        alert: 'ATCGatewayInvalidSignInRequests',
        expr: buildEventCount('kind="authorize_invalid"', ['reason', 'route']),
        for: '0m',
        labels: { severity: 'warning' },
        annotations: {
          summary: `The atc gateway rejected ${count} invalid request(s), {{ $labels.reason }} on {{ $labels.route }}, in the last ${window}.`,
        },
      },
      {
        alert: 'ATCGatewayOwnerSignedIn',
        expr: buildEventCount('kind="owner_auth", outcome="succeeded"', ['method', 'route']),
        for: '0m',
        labels: { severity: 'notice' },
        annotations: {
          summary: `The owner signed in to the atc gateway ${count} time(s) by {{ $labels.method }} in the last ${window}.`,
        },
      },
      {
        alert: 'ATCGatewayOwnerAuthFailed',
        expr: buildEventCount('kind="owner_auth", outcome="failed"', ['method', 'reason', 'route']),
        for: '0m',
        labels: { severity: 'warning' },
        annotations: {
          summary: `${count} owner sign-in(s) to the atc gateway by {{ $labels.method }} failed with {{ $labels.reason }} in the last ${window}.`,
        },
      },
      {
        alert: 'ATCGatewayConsentAllowed',
        expr: buildEventCount('kind="consent", outcome="allowed"', []),
        for: '0m',
        labels: { severity: 'notice' },
        annotations: {
          summary: `The owner allowed ${count} client consent(s) at the atc gateway in the last ${window}.`,
        },
      },
      {
        alert: 'ATCGatewayConsentDenied',
        expr: buildEventCount('kind="consent", outcome="denied"', ['reason']),
        for: '0m',
        labels: { severity: 'notice' },
        annotations: {
          summary: `The owner denied ${count} client consent(s) at the atc gateway, reason {{ $labels.reason }}, in the last ${window}.`,
        },
      },
      {
        alert: 'ATCGatewaySecurityEventsSuppressed',
        expr: buildEventCount('kind="suppressed"', ['reason'], atcSecurityEvents.suppressedMetric),
        for: '0m',
        labels: { severity: 'warning' },
        annotations: {
          summary: `atc's burst cap dropped ${count} {{ $labels.reason }} event(s) in the last ${window}, so the other sign-in alerts undercount them.`,
        },
      },
      {
        alert: 'ATCGatewayUnrecognizedSecurityEvents',
        expr: buildEventCount('kind="other"', []),
        for: '0m',
        labels: { severity: 'warning' },
        annotations: {
          summary: `${count} atc security line(s) did not match the event contract in the last ${window}, so Alloy counted them without their fields.`,
        },
      },
    ] satisfies AlertRule[],
  };
}

// The events of one selector in the window, summed per label set and kept above zero. increase()
// sees no rise in a series Alloy makes at its first event, or restores at the same value after a
// restart, so a series new in the window, or from an Alloy started in it, counts whole.
function buildEventCount(
  selector: string,
  by: readonly string[],
  metric: string = atcSecurityEvents.eventsMetric,
): string {
  const series = `${metric}{${selector}}`;
  const restarted = `changes(process_start_time_seconds[${window}]) > 0`;

  return `sum by (${by.join(', ')}) ((${series} unless ${series} offset ${window}) or (${series} and on (instance) ${restarted}) or increase(${series}[${window}])) > 0`;
}
