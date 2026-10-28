import { expect, test } from 'bun:test';
import { buildEgressDenyNetworkPolicySpec } from './build-egress-deny-network-policy-spec.ts';

test("it selects every pod and allows egress to every address but the tailnet range and Docker's subnet", () => {
  expect(buildEgressDenyNetworkPolicySpec()).toStrictEqual({
    podSelector: {},
    policyTypes: ['Egress'],
    egress: [
      {
        to: [{ ipBlock: { cidr: '0.0.0.0/0', except: ['100.64.0.0/10', '10.88.0.0/16'] } }],
      },
    ],
  });
});
