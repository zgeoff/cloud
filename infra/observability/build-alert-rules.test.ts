// each test asserts a hand-written spec whole, as one literal, so its body is long
/* oxlint-disable max-lines-per-function */
import { expect, test } from 'bun:test';
import { buildMockATCDaemonEndpoint } from '../test-utils/build-mock-atc-daemon-endpoint.ts';
import { buildAlertRules } from './build-alert-rules.ts';

test.each([
  ['no inputs', undefined],
  ['atcDaemons undefined', { atcDaemons: undefined }],
  ['an empty atcDaemons', { atcDaemons: [] }],
  ['nixieReadinessURL undefined', { nixieReadinessURL: undefined }],
])('it builds the geoff-cloud group without its optional rules given %s', (_kind, inputs) => {
  expect(buildAlertRules(inputs)).toStrictEqual([
    {
      name: 'geoff-cloud',
      rules: [
        {
          alert: 'ImpdLocalHealthDown',
          expr: 'impd_local_health_up == 0',
          for: '2m',
          labels: { severity: 'critical' },
          annotations: { summary: 'impd fails its loopback health check on geoffcloud.' },
        },
        {
          alert: 'ImpdLocalHealthStale',
          expr: 'time() - impd_local_health_last_check_timestamp_seconds > 300 or absent(impd_local_health_up)',
          for: '2m',
          labels: { severity: 'warning' },
          annotations: { summary: 'impd health probe has not reported for over 5 minutes.' },
        },
        {
          alert: 'HostBehindLatestBuild',
          expr: 'host_build_lag_seconds > 86400',
          for: '0m',
          labels: { severity: 'warning' },
          annotations: {
            summary:
              'geoffcloud has run an older {{ $labels.part }} than the latest green main build for over 24 hours; switch the host.',
          },
        },
        {
          alert: 'HostBuildLagStale',
          expr: 'time() - host_build_lag_last_check_timestamp_seconds > 10800 or absent(host_build_lag_last_check_timestamp_seconds)',
          for: '5m',
          labels: { severity: 'warning' },
          annotations: { summary: 'The host build lag check has not reported for over 3 hours.' },
        },
        {
          alert: 'TargetDown',
          expr: 'up == 0',
          for: '5m',
          labels: { severity: 'warning' },
          annotations: {
            summary: 'Scrape target {{ $labels.job }} {{ $labels.instance }} is down.',
          },
        },
        {
          alert: 'CloudflaredNoConnections',
          expr: 'sum(cloudflared_tunnel_ha_connections) == 0 or absent(cloudflared_tunnel_ha_connections) or absent(up{namespace="ingress", pod=~"cloudflared-.*"} == 1)',
          for: '5m',
          labels: { severity: 'critical' },
          annotations: { summary: 'cloudflared holds no tunnel connection to Cloudflare.' },
        },
        {
          alert: 'ImpHealthUnreachable',
          expr: 'probe_success{target="imp-health"} == 0 or absent(probe_success{target="imp-health"})',
          for: '5m',
          labels: { severity: 'critical' },
          annotations: {
            summary: 'https://imps.geoff.cloud/health fails from the cluster over the tailnet.',
          },
        },
        {
          alert: 'ContainerOOMKilled',
          expr: 'increase(kube_pod_container_status_restarts_total[10m]) > 0 and on (namespace, pod, container) kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1',
          for: '0m',
          labels: { severity: 'warning' },
          annotations: {
            summary:
              'Container {{ $labels.namespace }}/{{ $labels.pod }} {{ $labels.container }} was OOM-killed.',
          },
        },
      ],
    },
  ]);
});

test("it alerts on geoffcloud's daemon under the plain atc-daemon target, after the cloudflared rule", () => {
  expect(
    buildAlertRules({
      atcDaemons: [
        buildMockATCDaemonEndpoint({
          name: 'geoffcloud',
          address: '100.69.47.33:8415',
          alertSeverity: 'critical',
        }),
      ],
    }),
  ).toStrictEqual([
    {
      name: 'geoff-cloud',
      rules: [
        {
          alert: 'ImpdLocalHealthDown',
          expr: 'impd_local_health_up == 0',
          for: '2m',
          labels: { severity: 'critical' },
          annotations: { summary: 'impd fails its loopback health check on geoffcloud.' },
        },
        {
          alert: 'ImpdLocalHealthStale',
          expr: 'time() - impd_local_health_last_check_timestamp_seconds > 300 or absent(impd_local_health_up)',
          for: '2m',
          labels: { severity: 'warning' },
          annotations: { summary: 'impd health probe has not reported for over 5 minutes.' },
        },
        {
          alert: 'HostBehindLatestBuild',
          expr: 'host_build_lag_seconds > 86400',
          for: '0m',
          labels: { severity: 'warning' },
          annotations: {
            summary:
              'geoffcloud has run an older {{ $labels.part }} than the latest green main build for over 24 hours; switch the host.',
          },
        },
        {
          alert: 'HostBuildLagStale',
          expr: 'time() - host_build_lag_last_check_timestamp_seconds > 10800 or absent(host_build_lag_last_check_timestamp_seconds)',
          for: '5m',
          labels: { severity: 'warning' },
          annotations: { summary: 'The host build lag check has not reported for over 3 hours.' },
        },
        {
          alert: 'TargetDown',
          expr: 'up == 0',
          for: '5m',
          labels: { severity: 'warning' },
          annotations: {
            summary: 'Scrape target {{ $labels.job }} {{ $labels.instance }} is down.',
          },
        },
        {
          alert: 'CloudflaredNoConnections',
          expr: 'sum(cloudflared_tunnel_ha_connections) == 0 or absent(cloudflared_tunnel_ha_connections) or absent(up{namespace="ingress", pod=~"cloudflared-.*"} == 1)',
          for: '5m',
          labels: { severity: 'critical' },
          annotations: { summary: 'cloudflared holds no tunnel connection to Cloudflare.' },
        },
        {
          alert: 'ATCDaemonUnreachable',
          expr: 'probe_success{target="atc-daemon"} == 0 or absent(probe_success{target="atc-daemon"})',
          for: '5m',
          labels: { severity: 'critical' },
          annotations: {
            summary: "atc's daemon at 100.69.47.33:8415 is unreachable from the cluster.",
          },
        },
        {
          alert: 'ImpHealthUnreachable',
          expr: 'probe_success{target="imp-health"} == 0 or absent(probe_success{target="imp-health"})',
          for: '5m',
          labels: { severity: 'critical' },
          annotations: {
            summary: 'https://imps.geoff.cloud/health fails from the cluster over the tailnet.',
          },
        },
        {
          alert: 'ContainerOOMKilled',
          expr: 'increase(kube_pod_container_status_restarts_total[10m]) > 0 and on (namespace, pod, container) kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1',
          for: '0m',
          labels: { severity: 'warning' },
          annotations: {
            summary:
              'Container {{ $labels.namespace }}/{{ $labels.pod }} {{ $labels.container }} was OOM-killed.',
          },
        },
      ],
    },
  ]);
});

test('it alerts on each daemon in order, at its own severity, any but geoffcloud under a target named for it', () => {
  expect(
    buildAlertRules({
      atcDaemons: [
        buildMockATCDaemonEndpoint({
          name: 'geoffcloud',
          address: '100.69.47.33:8415',
          alertSeverity: 'critical',
        }),
        buildMockATCDaemonEndpoint({
          name: 'home-pc',
          address: '100.67.122.120:8415',
          alertSeverity: 'warning',
        }),
      ],
    }),
  ).toStrictEqual([
    {
      name: 'geoff-cloud',
      rules: [
        {
          alert: 'ImpdLocalHealthDown',
          expr: 'impd_local_health_up == 0',
          for: '2m',
          labels: { severity: 'critical' },
          annotations: { summary: 'impd fails its loopback health check on geoffcloud.' },
        },
        {
          alert: 'ImpdLocalHealthStale',
          expr: 'time() - impd_local_health_last_check_timestamp_seconds > 300 or absent(impd_local_health_up)',
          for: '2m',
          labels: { severity: 'warning' },
          annotations: { summary: 'impd health probe has not reported for over 5 minutes.' },
        },
        {
          alert: 'HostBehindLatestBuild',
          expr: 'host_build_lag_seconds > 86400',
          for: '0m',
          labels: { severity: 'warning' },
          annotations: {
            summary:
              'geoffcloud has run an older {{ $labels.part }} than the latest green main build for over 24 hours; switch the host.',
          },
        },
        {
          alert: 'HostBuildLagStale',
          expr: 'time() - host_build_lag_last_check_timestamp_seconds > 10800 or absent(host_build_lag_last_check_timestamp_seconds)',
          for: '5m',
          labels: { severity: 'warning' },
          annotations: { summary: 'The host build lag check has not reported for over 3 hours.' },
        },
        {
          alert: 'TargetDown',
          expr: 'up == 0',
          for: '5m',
          labels: { severity: 'warning' },
          annotations: {
            summary: 'Scrape target {{ $labels.job }} {{ $labels.instance }} is down.',
          },
        },
        {
          alert: 'CloudflaredNoConnections',
          expr: 'sum(cloudflared_tunnel_ha_connections) == 0 or absent(cloudflared_tunnel_ha_connections) or absent(up{namespace="ingress", pod=~"cloudflared-.*"} == 1)',
          for: '5m',
          labels: { severity: 'critical' },
          annotations: { summary: 'cloudflared holds no tunnel connection to Cloudflare.' },
        },
        {
          alert: 'ATCDaemonUnreachable',
          expr: 'probe_success{target="atc-daemon"} == 0 or absent(probe_success{target="atc-daemon"})',
          for: '5m',
          labels: { severity: 'critical' },
          annotations: {
            summary: "atc's daemon at 100.69.47.33:8415 is unreachable from the cluster.",
          },
        },
        {
          alert: 'ATCDaemonUnreachable',
          expr: 'probe_success{target="atc-daemon-home-pc"} == 0 or absent(probe_success{target="atc-daemon-home-pc"})',
          for: '5m',
          labels: { severity: 'warning' },
          annotations: {
            summary: "atc's daemon at 100.67.122.120:8415 is unreachable from the cluster.",
          },
        },
        {
          alert: 'ImpHealthUnreachable',
          expr: 'probe_success{target="imp-health"} == 0 or absent(probe_success{target="imp-health"})',
          for: '5m',
          labels: { severity: 'critical' },
          annotations: {
            summary: 'https://imps.geoff.cloud/health fails from the cluster over the tailnet.',
          },
        },
        {
          alert: 'ContainerOOMKilled',
          expr: 'increase(kube_pod_container_status_restarts_total[10m]) > 0 and on (namespace, pod, container) kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1',
          for: '0m',
          labels: { severity: 'warning' },
          annotations: {
            summary:
              'Container {{ $labels.namespace }}/{{ $labels.pod }} {{ $labels.container }} was OOM-killed.',
          },
        },
      ],
    },
  ]);
});

test("it alerts on nixie's failing turns from the nixie-turns probe, after the imp health rule", () => {
  expect(
    buildAlertRules({
      nixieReadinessURL: 'http://nixie.nixie.svc.cluster.local:8080/health/ready',
    }),
  ).toStrictEqual([
    {
      name: 'geoff-cloud',
      rules: [
        {
          alert: 'ImpdLocalHealthDown',
          expr: 'impd_local_health_up == 0',
          for: '2m',
          labels: { severity: 'critical' },
          annotations: { summary: 'impd fails its loopback health check on geoffcloud.' },
        },
        {
          alert: 'ImpdLocalHealthStale',
          expr: 'time() - impd_local_health_last_check_timestamp_seconds > 300 or absent(impd_local_health_up)',
          for: '2m',
          labels: { severity: 'warning' },
          annotations: { summary: 'impd health probe has not reported for over 5 minutes.' },
        },
        {
          alert: 'HostBehindLatestBuild',
          expr: 'host_build_lag_seconds > 86400',
          for: '0m',
          labels: { severity: 'warning' },
          annotations: {
            summary:
              'geoffcloud has run an older {{ $labels.part }} than the latest green main build for over 24 hours; switch the host.',
          },
        },
        {
          alert: 'HostBuildLagStale',
          expr: 'time() - host_build_lag_last_check_timestamp_seconds > 10800 or absent(host_build_lag_last_check_timestamp_seconds)',
          for: '5m',
          labels: { severity: 'warning' },
          annotations: { summary: 'The host build lag check has not reported for over 3 hours.' },
        },
        {
          alert: 'TargetDown',
          expr: 'up == 0',
          for: '5m',
          labels: { severity: 'warning' },
          annotations: {
            summary: 'Scrape target {{ $labels.job }} {{ $labels.instance }} is down.',
          },
        },
        {
          alert: 'CloudflaredNoConnections',
          expr: 'sum(cloudflared_tunnel_ha_connections) == 0 or absent(cloudflared_tunnel_ha_connections) or absent(up{namespace="ingress", pod=~"cloudflared-.*"} == 1)',
          for: '5m',
          labels: { severity: 'critical' },
          annotations: { summary: 'cloudflared holds no tunnel connection to Cloudflare.' },
        },
        {
          alert: 'ImpHealthUnreachable',
          expr: 'probe_success{target="imp-health"} == 0 or absent(probe_success{target="imp-health"})',
          for: '5m',
          labels: { severity: 'critical' },
          annotations: {
            summary: 'https://imps.geoff.cloud/health fails from the cluster over the tailnet.',
          },
        },
        {
          alert: 'NixieTurnsFailing',
          expr: 'probe_success{target="nixie-turns"} == 0 or absent(probe_success{target="nixie-turns"})',
          for: '5m',
          labels: { severity: 'critical' },
          annotations: {
            summary:
              "nixie's turns keep failing, or http://nixie.nixie.svc.cluster.local:8080/health/ready does not report them passing.",
          },
        },
        {
          alert: 'ContainerOOMKilled',
          expr: 'increase(kube_pod_container_status_restarts_total[10m]) > 0 and on (namespace, pod, container) kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1',
          for: '0m',
          labels: { severity: 'warning' },
          annotations: {
            summary:
              'Container {{ $labels.namespace }}/{{ $labels.pod }} {{ $labels.container }} was OOM-killed.',
          },
        },
      ],
    },
  ]);
});
