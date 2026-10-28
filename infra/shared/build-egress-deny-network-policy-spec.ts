import type { input } from '@pulumi/kubernetes/types';
import { topology } from '@zgeoff/cloud-topology';

export const egressDenyPolicyName = 'egress-deny';

export function buildEgressDenyNetworkPolicySpec(): input.networking.v1.NetworkPolicySpec {
  return {
    podSelector: {},
    policyTypes: ['Egress'],

    // A deny of every address would cut each pod's path to the Kubernetes API, which arrives on
    // the node's public address after kube-proxy's DNAT.
    egress: [
      {
        to: [
          {
            ipBlock: {
              cidr: '0.0.0.0/0',
              except: [topology.tailnet.cidr, topology.podman.subnet],
            },
          },
        ],
      },
    ],
  };
}
