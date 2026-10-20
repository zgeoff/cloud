import type { input } from '@pulumi/kubernetes/types';
import { buildEgressAllowNetworkPolicySpec } from './build-egress-allow-network-policy-spec.ts';
import {
  buildEgressDenyNetworkPolicySpec,
  egressDenyPolicyName,
} from './build-egress-deny-network-policy-spec.ts';
import { collectEgressDenyNamespaces } from './collect-egress-deny-namespaces.ts';
import { egressAllows } from './egress-allows.ts';

interface NetworkPolicyManifest {
  readonly apiVersion: 'networking.k8s.io/v1';
  readonly kind: 'NetworkPolicy';
  readonly metadata: { readonly name: string; readonly namespace: string };
  readonly spec: input.networking.v1.NetworkPolicySpec;
}

// every egress deny and allow the program creates, as the manifests the NixOS check applies
export function buildNetworkPolicyManifests(): NetworkPolicyManifest[] {
  const denies = collectEgressDenyNamespaces().map((namespace) =>
    buildManifest(egressDenyPolicyName, namespace, buildEgressDenyNetworkPolicySpec()),
  );

  const allows = Object.values(egressAllows).map((allow) =>
    buildManifest(allow.name, allow.namespace, buildEgressAllowNetworkPolicySpec(allow)),
  );

  return [...denies, ...allows];
}

function buildManifest(
  name: string,
  namespace: string,
  spec: input.networking.v1.NetworkPolicySpec,
): NetworkPolicyManifest {
  return {
    apiVersion: 'networking.k8s.io/v1',
    kind: 'NetworkPolicy',
    metadata: { name, namespace },
    spec,
  };
}
