import { expect, test } from 'bun:test';
import { buildOnePasswordConnectNetworkPolicySpec } from './build-onepassword-connect-network-policy-spec.ts';

test('it selects the Connect pod and admits no ingress, leaving egress open', () => {
  expect(buildOnePasswordConnectNetworkPolicySpec()).toStrictEqual({
    podSelector: { matchLabels: { app: 'onepassword-connect' } },
    policyTypes: ['Ingress'],
    ingress: [],
  });
});
