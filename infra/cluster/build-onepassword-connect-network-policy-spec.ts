import type { input } from '@pulumi/kubernetes/types';
import { onePasswordConnectLabels } from './build-onepassword-connect-spec.ts';

// Connect's NetworkPolicy: no ingress, so every pod is refused. The host relay still passes, as
// kube-router admits the node's own addresses before any policy (docs/architecture/workloads/
// onepassword-connect.md). Egress stays open for connect-sync.
export function buildOnePasswordConnectNetworkPolicySpec(): input.networking.v1.NetworkPolicySpec {
  return {
    podSelector: { matchLabels: onePasswordConnectLabels },
    policyTypes: ['Ingress'],
    ingress: [],
  };
}
