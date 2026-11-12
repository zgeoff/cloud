import type { input } from '@pulumi/kubernetes/types';

export const egressDenyAllPolicyName = 'egress-deny-all';

// Every pod of the namespace dials nothing, the Kubernetes API included, unless a policy of its
// own selects it and lists what it may reach.
export function buildEgressDenyAllNetworkPolicySpec(): input.networking.v1.NetworkPolicySpec {
  return { podSelector: {}, policyTypes: ['Egress'], egress: [] };
}
