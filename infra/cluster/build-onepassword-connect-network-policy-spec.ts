import type { input } from '@pulumi/kubernetes/types';
import { onePasswordConnectLabels } from './build-onepassword-connect-spec.ts';

export function buildOnePasswordConnectNetworkPolicySpec(): input.networking.v1.NetworkPolicySpec {
  return {
    podSelector: { matchLabels: onePasswordConnectLabels },

    // egress stays open for connect-sync
    policyTypes: ['Ingress'],

    // No ingress refuses every pod, yet the host relay still passes: kube-router admits the node's
    // own addresses before any policy.
    ingress: [],
  };
}
