import type { input } from '@pulumi/kubernetes/types';
import type { EgressAllow } from './egress-allows.ts';

export function buildEgressAllowNetworkPolicySpec(
  allow: EgressAllow,
): input.networking.v1.NetworkPolicySpec {
  return {
    podSelector: { matchLabels: allow.podLabels },
    policyTypes: ['Egress'],

    // one rule per destination, so a pod reaches each address on its own port only
    egress: allow.destinations.map((destination) => ({
      to: [{ ipBlock: { cidr: `${destination.address}/32` } }],
      ports: [{ protocol: 'TCP', port: destination.port }],
    })),
  };
}
