import { expect, test } from 'bun:test';
import { buildATCSignInRules } from './build-atc-sign-in-rules.ts';

test('it alerts once per category of atc sign-in event, with the count of the last five minutes, counting a new series whole', () => {
  expect(buildATCSignInRules()).toStrictEqual({
    name: 'atc-sign-in',
    rules: [
      {
        alert: 'ATCGatewaySignInStarted',
        expr: 'sum by (route) ((loki_process_custom_atc_security_events_total{kind="authorize_started", outcome="accepted"} unless loki_process_custom_atc_security_events_total{kind="authorize_started", outcome="accepted"} offset 5m) or increase(loki_process_custom_atc_security_events_total{kind="authorize_started", outcome="accepted"}[5m])) > 0',
        for: '0m',
        labels: { severity: 'info' },
        annotations: {
          summary:
            'The atc gateway accepted {{ $value | printf "%.0f" }} sign-in start(s) in the last 5m.',
        },
      },
      {
        alert: 'ATCGatewaySignInRateLimited',
        expr: 'sum by (reason) ((loki_process_custom_atc_security_events_total{kind="authorize_started", outcome="rejected"} unless loki_process_custom_atc_security_events_total{kind="authorize_started", outcome="rejected"} offset 5m) or increase(loki_process_custom_atc_security_events_total{kind="authorize_started", outcome="rejected"}[5m])) > 0',
        for: '0m',
        labels: { severity: 'warning' },
        annotations: {
          summary:
            'The atc gateway refused {{ $value | printf "%.0f" }} sign-in start(s) at its rate limit in the last 5m. The limit counts every client together, so the alert names no source.',
        },
      },
      {
        alert: 'ATCGatewayInvalidSignInRequests',
        expr: 'sum by (reason, route) ((loki_process_custom_atc_security_events_total{kind="authorize_invalid"} unless loki_process_custom_atc_security_events_total{kind="authorize_invalid"} offset 5m) or increase(loki_process_custom_atc_security_events_total{kind="authorize_invalid"}[5m])) > 0',
        for: '0m',
        labels: { severity: 'warning' },
        annotations: {
          summary:
            'The atc gateway rejected {{ $value | printf "%.0f" }} invalid request(s), {{ $labels.reason }} on {{ $labels.route }}, in the last 5m.',
        },
      },
      {
        alert: 'ATCGatewayOwnerSignedIn',
        expr: 'sum by (method, route) ((loki_process_custom_atc_security_events_total{kind="owner_auth", outcome="succeeded"} unless loki_process_custom_atc_security_events_total{kind="owner_auth", outcome="succeeded"} offset 5m) or increase(loki_process_custom_atc_security_events_total{kind="owner_auth", outcome="succeeded"}[5m])) > 0',
        for: '0m',
        labels: { severity: 'info' },
        annotations: {
          summary:
            'The owner signed in to the atc gateway {{ $value | printf "%.0f" }} time(s) by {{ $labels.method }} in the last 5m.',
        },
      },
      {
        alert: 'ATCGatewayOwnerAuthFailed',
        expr: 'sum by (method, reason, route) ((loki_process_custom_atc_security_events_total{kind="owner_auth", outcome="failed"} unless loki_process_custom_atc_security_events_total{kind="owner_auth", outcome="failed"} offset 5m) or increase(loki_process_custom_atc_security_events_total{kind="owner_auth", outcome="failed"}[5m])) > 0',
        for: '0m',
        labels: { severity: 'warning' },
        annotations: {
          summary:
            '{{ $value | printf "%.0f" }} owner sign-in(s) to the atc gateway by {{ $labels.method }} failed with {{ $labels.reason }} in the last 5m.',
        },
      },
      {
        alert: 'ATCGatewayConsentAllowed',
        expr: 'sum by () ((loki_process_custom_atc_security_events_total{kind="consent", outcome="allowed"} unless loki_process_custom_atc_security_events_total{kind="consent", outcome="allowed"} offset 5m) or increase(loki_process_custom_atc_security_events_total{kind="consent", outcome="allowed"}[5m])) > 0',
        for: '0m',
        labels: { severity: 'info' },
        annotations: {
          summary:
            'The owner allowed {{ $value | printf "%.0f" }} client consent(s) at the atc gateway in the last 5m.',
        },
      },
      {
        alert: 'ATCGatewayConsentDenied',
        expr: 'sum by (reason) ((loki_process_custom_atc_security_events_total{kind="consent", outcome="denied"} unless loki_process_custom_atc_security_events_total{kind="consent", outcome="denied"} offset 5m) or increase(loki_process_custom_atc_security_events_total{kind="consent", outcome="denied"}[5m])) > 0',
        for: '0m',
        labels: { severity: 'info' },
        annotations: {
          summary:
            'The owner denied {{ $value | printf "%.0f" }} client consent(s) at the atc gateway, reason {{ $labels.reason }}, in the last 5m.',
        },
      },
      {
        alert: 'ATCGatewaySecurityEventsSuppressed',
        expr: 'sum by (reason) ((loki_process_custom_atc_security_suppressed_events_total{kind="suppressed"} unless loki_process_custom_atc_security_suppressed_events_total{kind="suppressed"} offset 5m) or increase(loki_process_custom_atc_security_suppressed_events_total{kind="suppressed"}[5m])) > 0',
        for: '0m',
        labels: { severity: 'warning' },
        annotations: {
          summary:
            'atc\'s burst cap dropped {{ $value | printf "%.0f" }} {{ $labels.reason }} event(s) in the last 5m, so the other sign-in alerts undercount them.',
        },
      },
      {
        alert: 'ATCGatewayUnrecognizedSecurityEvents',
        expr: 'sum by () ((loki_process_custom_atc_security_events_total{kind="other"} unless loki_process_custom_atc_security_events_total{kind="other"} offset 5m) or increase(loki_process_custom_atc_security_events_total{kind="other"}[5m])) > 0',
        for: '0m',
        labels: { severity: 'warning' },
        annotations: {
          summary:
            '{{ $value | printf "%.0f" }} atc security line(s) did not match the event contract in the last 5m, so Alloy counted them without their fields.',
        },
      },
    ],
  });
});
