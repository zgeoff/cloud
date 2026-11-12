import type { input } from '@pulumi/kubernetes/types';
import { buildEgressAllowNetworkPolicySpec } from './build-egress-allow-network-policy-spec.ts';
import {
  buildEgressDenyAllNetworkPolicySpec,
  egressDenyAllPolicyName,
} from './build-egress-deny-all-network-policy-spec.ts';
import {
  buildEgressDenyNetworkPolicySpec,
  egressDenyPolicyName,
} from './build-egress-deny-network-policy-spec.ts';
import { buildPepysEgressPolicySpecs } from './build-pepys-egress-policy-specs.ts';
import { clusterNamespaceNames, clusterNamespaces } from './cluster-namespaces.ts';
import { collectEgressDenyNamespaces } from './collect-egress-deny-namespaces.ts';
import { egressAllows } from './egress-allows.ts';
import { pepysWorkloads } from './pepys-workloads.ts';

interface NetworkPolicyManifest {
  readonly apiVersion: 'networking.k8s.io/v1';
  readonly kind: 'NetworkPolicy';
  readonly metadata: { readonly name: string; readonly namespace: string };
  readonly spec: input.networking.v1.NetworkPolicySpec;
}

// the NixOS check applies these manifests
export function buildNetworkPolicyManifests(): NetworkPolicyManifest[] {
  const denies = collectEgressDenyNamespaces().map((namespace) =>
    buildManifest(egressDenyPolicyName, namespace, buildEgressDenyNetworkPolicySpec()),
  );

  const allows = Object.values(egressAllows).map((allow) =>
    buildManifest(allow.name, allow.namespace, buildEgressAllowNetworkPolicySpec(allow)),
  );

  const denyAlls = clusterNamespaceNames
    .filter((namespace) => clusterNamespaces[namespace].egress === 'deny-all')
    .map((namespace) =>
      buildManifest(egressDenyAllPolicyName, namespace, buildEgressDenyAllNetworkPolicySpec()),
    );

  const pepys = Object.entries(buildPepysEgressPolicySpecs()).map(([name, spec]) =>
    buildManifest(name, pepysWorkloads.namespace, spec),
  );

  return [...denies, ...allows, ...denyAlls, ...pepys];
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
