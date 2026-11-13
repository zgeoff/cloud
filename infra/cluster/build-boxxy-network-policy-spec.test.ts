import { expect, test } from 'bun:test';
import { buildBoxxyNetworkPolicySpec } from './build-boxxy-network-policy-spec.ts';

test("it admits no pod to either server port and only Prometheus to the rules sidecar's metrics, leaving egress to the namespace deny", () => {
  expect(buildBoxxyNetworkPolicySpec()).toStrictEqual({
    podSelector: { matchLabels: { app: 'boxxy-server' } },
    policyTypes: ['Ingress'],
    ingress: [
      {
        from: [
          {
            namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'observability' } },
            podSelector: { matchLabels: { 'app.kubernetes.io/name': 'prometheus' } },
          },
        ],
        ports: [{ protocol: 'TCP', port: 2020 }],
      },
    ],
  });
});
