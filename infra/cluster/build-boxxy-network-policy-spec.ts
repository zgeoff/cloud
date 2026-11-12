import type { input } from '@pulumi/kubernetes/types';
import { boxxyLabels } from './build-boxxy-spec.ts';

export function buildBoxxyNetworkPolicySpec(): input.networking.v1.NetworkPolicySpec {
  return {
    podSelector: { matchLabels: boxxyLabels },

    // egress keeps the namespace's deny: the server calls atc and pepys, and GitHub when set
    policyTypes: ['Ingress'],

    // No pod reaches either port; a port-forward connects on the pod's loopback, and kube-router
    // admits the node's own addresses, so the owner's forward and the host relay still pass.
    ingress: [],
  };
}
