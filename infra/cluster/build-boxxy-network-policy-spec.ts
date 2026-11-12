import type { input } from '@pulumi/kubernetes/types';
import { boxxyLabels } from './build-boxxy-spec.ts';
import { boxxyOwnerPort } from './render-boxxy-config.ts';

// the namespace of the tailnet Traefik, which serves the owner's route
const tailnetIngressNamespace = 'nixie-ingress';

export function buildBoxxyNetworkPolicySpec(): input.networking.v1.NetworkPolicySpec {
  return {
    podSelector: { matchLabels: boxxyLabels },

    // egress keeps the namespace's deny: the server calls atc and pepys, and GitHub when set
    policyTypes: ['Ingress'],

    // The owner port admits the tailnet Traefik's pods only, so no other pod reaches the listener
    // that takes no token. No pod reaches the worker port; the host relay still passes, because
    // kube-router admits the node's own addresses before any policy.
    ingress: [
      {
        from: [
          {
            namespaceSelector: {
              matchLabels: { 'kubernetes.io/metadata.name': tailnetIngressNamespace },
            },
          },
        ],
        ports: [{ protocol: 'TCP', port: boxxyOwnerPort }],
      },
    ],
  };
}
