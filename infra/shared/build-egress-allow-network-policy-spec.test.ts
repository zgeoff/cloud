import { expect, test } from 'bun:test';
import { buildEgressAllowNetworkPolicySpec } from './build-egress-allow-network-policy-spec.ts';
import { egressAllows } from './egress-allows.ts';

test("it lets the atc gateway's pod reach the host's daemon and home-pc's daemon on the daemon port only", () => {
  expect(buildEgressAllowNetworkPolicySpec(egressAllows.atcGateway)).toStrictEqual({
    podSelector: { matchLabels: { app: 'atc-gateway' } },
    policyTypes: ['Egress'],
    egress: [
      { to: [{ ipBlock: { cidr: '100.69.47.33/32' } }], ports: [{ protocol: 'TCP', port: 8415 }] },
      {
        to: [{ ipBlock: { cidr: '100.67.122.120/32' } }],
        ports: [{ protocol: 'TCP', port: 8415 }],
      },
    ],
  });
});

test("it lets the atc daemon probe's pod reach the host's daemon and home-pc's daemon on the daemon port only", () => {
  expect(buildEgressAllowNetworkPolicySpec(egressAllows.atcDaemonProbe)).toStrictEqual({
    podSelector: { matchLabels: { app: 'atc-daemon-probe' } },
    policyTypes: ['Egress'],
    egress: [
      { to: [{ ipBlock: { cidr: '100.69.47.33/32' } }], ports: [{ protocol: 'TCP', port: 8415 }] },
      {
        to: [{ ipBlock: { cidr: '100.67.122.120/32' } }],
        ports: [{ protocol: 'TCP', port: 8415 }],
      },
    ],
  });
});

test("it lets the imp health probe's pod reach impd's tailnet address on 443 only", () => {
  expect(buildEgressAllowNetworkPolicySpec(egressAllows.impHealthProbe)).toStrictEqual({
    podSelector: { matchLabels: { app: 'imp-health-probe' } },
    policyTypes: ['Egress'],
    egress: [
      { to: [{ ipBlock: { cidr: '100.75.9.119/32' } }], ports: [{ protocol: 'TCP', port: 443 }] },
    ],
  });
});

test("it lets cloudflared's pod reach the preview webhook on the host's tailnet address only", () => {
  expect(buildEgressAllowNetworkPolicySpec(egressAllows.cloudflared)).toStrictEqual({
    podSelector: { matchLabels: { app: 'cloudflared' } },
    policyTypes: ['Egress'],
    egress: [
      { to: [{ ipBlock: { cidr: '100.69.47.33/32' } }], ports: [{ protocol: 'TCP', port: 8418 }] },
    ],
  });
});
