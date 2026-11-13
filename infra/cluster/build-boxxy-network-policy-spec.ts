import type { input } from '@pulumi/kubernetes/types';
import { boxxyRulesSyncNames } from '../shared/boxxy-rules-sync-names.ts';
import { boxxyLabels } from './build-boxxy-spec.ts';

// one peer with both selectors: as two peers, they would admit every pod of the namespace; the
// Prometheus operator labels each Prometheus pod with its name
const prometheusPeer: input.networking.v1.NetworkPolicyPeer = {
  namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'observability' } },
  podSelector: { matchLabels: { 'app.kubernetes.io/name': 'prometheus' } },
};

export function buildBoxxyNetworkPolicySpec(): input.networking.v1.NetworkPolicySpec {
  return {
    podSelector: { matchLabels: boxxyLabels },

    // egress keeps the namespace's deny: the server calls atc and pepys, and GitHub when set, and
    // the rules sidecar fetches from GitHub
    policyTypes: ['Ingress'],

    // No pod reaches either server port; a port-forward connects on the pod's loopback, and
    // kube-router admits the node's own addresses, so the owner's forward and the host relay still
    // pass. Prometheus scrapes the rules sidecar's metrics.
    ingress: [
      {
        from: [prometheusPeer],
        ports: [{ protocol: 'TCP', port: boxxyRulesSyncNames.httpPortNumber }],
      },
    ],
  };
}
