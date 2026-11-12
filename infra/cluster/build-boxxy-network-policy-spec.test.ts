import { expect, test } from 'bun:test';
import { buildBoxxyNetworkPolicySpec } from './build-boxxy-network-policy-spec.ts';

test("it admits the tailnet Traefik's namespace to the owner port only, and no pod to the worker port, leaving egress to the namespace deny", () => {
  expect(buildBoxxyNetworkPolicySpec()).toStrictEqual({
    podSelector: { matchLabels: { app: 'boxxy-server' } },
    policyTypes: ['Ingress'],
    ingress: [
      {
        from: [
          {
            namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'nixie-ingress' } },
          },
        ],
        ports: [{ protocol: 'TCP', port: 8090 }],
      },
    ],
  });
});
