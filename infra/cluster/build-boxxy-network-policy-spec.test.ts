import { expect, test } from 'bun:test';
import { buildBoxxyNetworkPolicySpec } from './build-boxxy-network-policy-spec.ts';

test('it admits no pod to either port, leaving egress to the namespace deny', () => {
  expect(buildBoxxyNetworkPolicySpec()).toStrictEqual({
    podSelector: { matchLabels: { app: 'boxxy-server' } },
    policyTypes: ['Ingress'],
    ingress: [],
  });
});
